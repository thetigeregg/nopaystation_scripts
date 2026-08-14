#!/bin/sh

ext="7z"
mime_type="application/x-7z-compressed"

sha256_choose() {
    if which sha256 > /dev/null 2>&1
    then
        MY_BINARIES="${MY_BINARIES} sha256"
        SHA256="sha256"
    else
        MY_BINARIES="${MY_BINARIES} sha256sum"
        SHA256="sha256sum"
    fi
}

my_sha256() {
    local file="${1}"

    case "$SHA256" in
        "sha256sum")
        sha256sum "${file}" | awk '{ print $1 }' ;;
        "sha256")
        sha256    "${file}" | awk '{ print $NF }' ;;
    esac
}

downloader_choose() {
    if which wget > /dev/null 2>&1
    then
        MY_BINARIES="${MY_BINARIES} wget"
        DOWNLOADER="wget"
    else
        MY_BINARIES="${MY_BINARIES} curl"
        DOWNLOADER="curl"
    fi
}

my_download_file() {
    local url="${1}"
    local destination="${2}"

    case "${DOWNLOADER}" in
        "wget")
        wget --no-verbose --show-progress -O "${destination}" "${url}" ;;
        "curl")
        curl --progress-bar -o "${destination}" "${url}" ;;
    esac
}

check_binaries(){
    local BINARIES="${1}"
    for bins in ${BINARIES}
    do
        if ! which ${bins} > /dev/null 2>&1
        then
            echo "${bins} isn't installed."
            echo "Please install it and try again"
            exit 1
        fi
    done
}

region_rename() {
    local NAME="${1}"

    if echo "${NAME}" | grep -q "\[USA\]"
    then
        local NAME="$(echo "${NAME}" | sed 's/USA/NTSC/g')"
    elif echo "${NAME}" | grep -q "\[JPN\]"
    then
        NAME="$(echo "${NAME}" | sed 's/JPN/NTSC-J/g')"
    elif echo "${NAME}" | grep -q "\[EUR\]"
    then
        NAME="$(echo "${NAME}" | sed 's/EUR/PAL/g')"
    elif echo "${NAME}" | grep -q "\[ASA\]"
    then
        NAME="$(echo "${NAME}" | sed 's/ASA/NTSC-C/g')"
    fi
    echo ${NAME}
}

sanitize_filename() {
    local NAME="${1}"
    echo "${NAME}" | tr -s '/\\:*?"<>|' '_'
}

check_valid_psv_id() {
    local TITLE_ID="${1}"
    if ! echo "${TITLE_ID}" | grep -q -E -i 'PCS[ABCDEFGH][0-9]{5}'
    then
        echo ""
        echo "Error"
        echo "Title ID is not valid."
        echo "It should be the following format:"
        echo "PCSA01234"
        echo "Check your title id parameter."
        exit 1
    fi
}

check_valid_psm_id() {
    local TITLE_ID="${1}"
    if ! echo "${TITLE_ID}" | grep -q -E -i 'NP[NPOQ]A[0-9]{5}'
    then
        echo ""
        echo "Error"
        echo "Title ID is not valid."
        echo "It should be the following format:"
        echo "NPNA01234"
        echo "Check your title id parameter."
        exit 1
    fi
}

check_valid_psp_id() {
    local TITLE_ID="${1}"
    if ! echo "${TITLE_ID}" | grep -q -E -i '[NU][PCL][UJEHA][DFGHJQSXZ][0-9]{5}'
    then
        echo ""
        echo "Error"
        echo "Title ID is not valid."
        echo "It should be the following format:"
        echo "NPUF00001"
        echo "Check your title id parameter."
        exit 1
    fi
}

human_size() {
    local BYTES="${1}"
    awk -v bytes="${BYTES}" 'BEGIN {
        if (bytes !~ /^[0-9]+$/) { print "?"; exit }
        split("B KB MB GB TB", units, " ")
        i = 1
        while (bytes >= 1024 && i < 5) { bytes /= 1024; i++ }
        printf "%.1f%s", bytes, units[i]
    }'
}

# Interactive fzf-driven search over a PS3_GAMES.tsv by game name, showing
# Title ID / Region / Media Type / Size for disambiguation between a game's
# many releases (physical vs digital, per-region, re-releases). Prints the
# selected Title ID(s) on stdout (one per line if MULTI="1"); prints nothing
# if the user cancels without selecting anything.
ps3_typeahead_search() {
    local GAMES_TSV="${1}"
    local MULTI="${2}"

    local CANDIDATES
    CANDIDATES="$(tail -n +2 "${GAMES_TSV}" | tr -d '\r' | awk -F'\t' '
        function human(bytes,    units, i) {
            if (bytes !~ /^[0-9]+$/) return "?"
            split("B KB MB GB TB", units, " ")
            i = 1
            while (bytes >= 1024 && i < 5) { bytes /= 1024; i++ }
            return sprintf("%.1f%s", bytes, units[i])
        }
        {
            id = $1; region = $2; name = $3; link = $4; size = $9
            type = (substr(id, 1, 2) == "NP") ? "Digital" : "Physical"
            if (link == "MISSING" || link == "CART ONLY") name = name " [NO LINK]"
            printf "%s\t%-9s %-7s %-8s %-8s %s\n", id, id, region, type, human(size), name
        }
    ')"

    if [ "${MULTI}" = "1" ]
    then
        echo "${CANDIDATES}" | fzf --delimiter="$(printf '\t')" --with-nth=2.. --multi \
            --height=90% --border --prompt="Search PS3 game title> " | cut -f1
    else
        echo "${CANDIDATES}" | fzf --delimiter="$(printf '\t')" --with-nth=2.. \
            --height=90% --border --prompt="Search PS3 game title> " | cut -f1
    fi
}

SERIALSTATION_API_BASE="https://api.serialstation.com/v1"

serialstation_fetch() {
    local URL="${1}"
    local RESPONSE

    RESPONSE="$(curl -fsS "${URL}")"
    if [ ${?} -ne 0 ] || [ -z "${RESPONSE}" ]
    then
        echo "ERROR: failed to reach SerialStation API (\"${URL}\")." >&2
        exit 3
    fi
    echo "${RESPONSE}"
}

# Print every Title ID (one per line, including the one given) that
# SerialStation considers part of the same game as ${1}. Requires
# NPS_DIR to be set (used to locate/create the on-disk cache).
serialstation_related_title_ids() {
    local TITLE_ID="${1}"
    local CACHE_DIR="${NPS_DIR}/.serialstation_cache"
    local CACHE_FILE="${CACHE_DIR}/${TITLE_ID}.ids"

    if [ -f "${CACHE_FILE}" ]
    then
        cat "${CACHE_FILE}"
        return 0
    fi

    local TITLE_JSON GAME_IDS GAME_ID GAME_JSON
    TITLE_JSON="$(serialstation_fetch "${SERIALSTATION_API_BASE}/title-ids/${TITLE_ID}")"

    GAME_IDS="$(echo "${TITLE_JSON}" | jq -r '.games[].id // empty')"
    if [ -z "${GAME_IDS}" ]
    then
        echo "ERROR: SerialStation has no game mapping for Title ID \"${TITLE_ID}\"." >&2
        exit 3
    fi

    mkdir -p "${CACHE_DIR}"

    {
        echo "${TITLE_ID}"
        for GAME_ID in ${GAME_IDS}
        do
            GAME_JSON="$(serialstation_fetch "${SERIALSTATION_API_BASE}/games/${GAME_ID}")"
            echo "${GAME_JSON}" | jq -r '.title_ids[]'
        done
    } | sort -u | tee "${CACHE_FILE}"
}

check_valid_ps3_id() {
    local TITLE_ID="${1}"
    if ! echo "${TITLE_ID}" | grep -q -E -i '[A-Z]{4}[0-9]{5}'
    then
        echo ""
        echo "Error"
        echo "Title ID is not valid."
        echo "It should be the following format:"
        echo "BCUS01234"
        echo "Check your title id parameter."
        exit 1
    fi
}

yesno_checksum() {
    local GAME_ID="${1}"
    while true
    do
        echo "Do you want to continue? (yes/no)"
        read INPUT
        case "${INPUT}" in
            Yes|YES|yes|Y|y)
                break
                ;;
            No|NO|no|n)
                echo "User aborted."
                test -e "${GAME_ID}.pkg" && rm "${GAME_ID}.pkg"
                if [ ${?} -eq 0 ]
                then
                    echo "Downloaded file removed."
                else
                    echo "Something went wrong while removing pkg file."
                fi
                exit 1
                ;;
        esac
    done
}
exit_if_fail() {
    local _msg="${1}"
    if [ "${?}" -ne 0 ]
    then
        echo "${_msg}"
        exit 1
    fi
}

check_announce_url() {
    local URL="${1}"
    echo "${URL}" | grep "^http" &> /dev/null
    if [ ${?} -ne 0 ]
    then
        echo "No valid announce url provided. Be sure that the url starts with \"http\" and has a correct hostname"
        exit 1
    fi
}

compare_checksum(){
    local LIST="${1}"
    local FILE="${2}"
    if [ -n "${LIST}" ]
    then
        if [ "${FILE}" != "${LIST}" ]
        then
            echo "Checksum of downloaded file does not match checksum in list"
            echo "${FILE} != ${LIST}"
            yesno_checksum
        fi
    else
        echo "No checksum available in *.tsv list."
        echo "Maybe you could report it:"
        echo "\"${FILE}\""
        echo ""
    fi
}
