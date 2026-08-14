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

# Writes an OSC 52 escape sequence to set the LOCAL terminal emulator's
# clipboard - works over ssh/docker exec since both just relay the raw
# pty byte stream, no forwarding needed. Support is terminal-dependent
# (iTerm2, Kitty, WezTerm, Windows Terminal, tmux with set-clipboard on,
# ...); if unsupported the escape sequence is simply ignored. Written
# straight to /dev/tty rather than stdout - callers (e.g. fzf's
# execute-silent) may discard/redirect stdout, but the terminal itself
# is still reachable through /dev/tty regardless.
my_copy_to_clipboard() {
    local TEXT="${1}"
    local B64
    B64="$(printf '%s' "${TEXT}" | base64 | tr -d '\n')"

    if [ -n "${TMUX}" ]
    then
        # tmux DCS passthrough: wrap the OSC52 sequence, doubling the
        # inner ESC, so tmux forwards it to the outer terminal instead of
        # swallowing it (needed on tmux versions/configs that don't
        # natively translate OSC52 themselves)
        printf '\033Ptmux;\033\033]52;c;%s\a\033\\' "${B64}" > /dev/tty
    else
        printf '\033]52;c;%s\a' "${B64}" > /dev/tty
    fi
}

# Best-effort browser opener: tries `open` (macOS) then `xdg-open`
# (Linux/BSD/WSL), backgrounded; degrades to an OSC 52 clipboard-copy
# attempt (see my_copy_to_clipboard) plus printing the URL if neither
# exists - the printed URL stays as a manual fallback since OSC 52
# support isn't guaranteed. Not a hard dependency of any script.
my_open_url() {
    local URL="${1}"
    if which open > /dev/null 2>&1
    then
        open "${URL}" > /dev/null 2>&1 &
    elif which xdg-open > /dev/null 2>&1
    then
        xdg-open "${URL}" > /dev/null 2>&1 &
    else
        my_copy_to_clipboard "${URL}"
        echo "No browser opener available. Attempted to copy to your local clipboard via OSC 52 (works over SSH/tmux if your terminal supports it) - if that didn't work, here's the URL: ${URL}" > /dev/tty
    fi
}

# One-shot search of SerialStation's title-id database by name (PS3 only).
# Prints candidates in the same "<TITLE_ID>\t<display line>" shape used by
# the local PS3_GAMES.tsv candidates, so callers can treat both sources
# identically. No Size column - the API doesn't carry it. Region is
# inferred from the 3rd letter of the Title ID type (documented for both
# physical and digital formats) - coarse, same ceiling as NPS's own TSV
# Region column, and can't distinguish sub-regions like Brazil from USA
# (both are "U").
ps3_serialstation_search() {
    local QUERY="${1}"

    if [ -z "${QUERY}" ]
    then
        return 0
    fi

    curl -fsS -G \
        --data-urlencode "name=${QUERY}" \
        --data-urlencode "system=PS3" \
        --data-urlencode "limit=50" \
        "${SERIALSTATION_API_BASE}/title-ids/" 2>/dev/null \
    | jq -r '.items[] | [.title_id, .title_id_type, .content_type, .name] | @tsv' 2>/dev/null \
    | awk -F'\t' '
        function region(type_code,    c) {
            c = substr(type_code, 3, 1)
            if (c == "A") return "Asia"
            if (c == "C") return "China"
            if (c == "E") return "Europe"
            if (c == "H") return "Hong Kong"
            if (c == "I") return "Internal"
            if (c == "J") return "Japan"
            if (c == "K") return "Korea"
            if (c == "P") return "Japan"
            if (c == "U") return "USA"
            if (c == "X") return "Firmware/SDK"
            return "?"
        }
        {
            id = $1; ttype = $2; ctype = $3; name = $4
            mtype = (substr(id, 1, 2) == "NP") ? "Digital" : "Physical"
            printf "api\t%s\t%-9s %-11s %-8s %-6s %s\n", id, id, region(ttype), mtype, ctype, name
        }
    '
}

# Interactive fzf-driven search for a PS3 Title ID by game name. Starts
# from the local PS3_GAMES.tsv (Title ID / Region / Media Type / Size
# columns), with in-session key bindings to switch to a one-shot
# SerialStation name search (ctrl-s - finds titles PS3_GAMES.tsv has no
# row for at all), back to the local results (ctrl-r), and to open the
# highlighted title's SerialStation page in a browser (ctrl-o).
#
# Every candidate row carries its origin ("local" or "api") as a hidden
# first field. Single-select (MULTI != "1", used by nps_ps3.sh) still
# prints a bare Title ID per line, unchanged. Multi-select (MULTI="1",
# used by nps_ps3_bundle.sh) prints "<source>\t<TITLE_ID>" per line
# instead, so the caller can tell which picks came from the SerialStation
# search. Prints nothing if the user cancels without selecting anything.
ps3_typeahead_search() {
    local GAMES_TSV="${1}"
    local MULTI="${2}"

    local WORKDIR
    WORKDIR="$(mktemp -d)"
    trap 'rm -rf "${WORKDIR}"' EXIT

    local CANDIDATES_FILE="${WORKDIR}/local.tsv"
    tail -n +2 "${GAMES_TSV}" | tr -d '\r' | awk -F'\t' '
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
            printf "local\t%s\t%-9s %-7s %-8s %-8s %s\n", id, id, region, type, human(size), name
        }
    ' > "${CANDIDATES_FILE}"

    # Standalone helper scripts referenced directly by the key bindings
    # below, instead of inlining logic into fzf's reload()/execute()
    # strings - keeps fzf's own paren/quote parsing out of the picture,
    # and lets fzf pass {q}/{1} as a single safely-quoted argument (matters
    # for query text like "asura's wrath").
    local SEARCH_SCRIPT="${WORKDIR}/search-api.sh"
    cat > "${SEARCH_SCRIPT}" <<EOF
#!/bin/sh
. "${SCRIPT_DIR}/functions.sh"
ps3_serialstation_search "\${1}"
EOF
    chmod +x "${SEARCH_SCRIPT}"

    local OPEN_SCRIPT="${WORKDIR}/open-url.sh"
    cat > "${OPEN_SCRIPT}" <<EOF
#!/bin/sh
. "${SCRIPT_DIR}/functions.sh"
ID="\${1}"
TYPE="\$(echo "\${ID}" | cut -c1-4)"
NUMBER="\$(echo "\${ID}" | cut -c5-9)"
my_open_url "https://serialstation.com/titles/\${TYPE}/\${NUMBER}"
EOF
    chmod +x "${OPEN_SCRIPT}"

    local HEADER="enter:select  tab:multi-select  ctrl-s:search SerialStation  ctrl-r:back to local results  ctrl-o:open on SerialStation"

    local MULTI_FLAG=""
    local OUT_FIELDS="2"
    if [ "${MULTI}" = "1" ]
    then
        MULTI_FLAG="--multi"
        OUT_FIELDS="1,2"
    fi

    cat "${CANDIDATES_FILE}" | fzf --delimiter="$(printf '\t')" --with-nth=3.. ${MULTI_FLAG} \
        --height=90% --border --prompt="Search PS3 game title> " \
        --header="${HEADER}" \
        --bind "ctrl-s:reload(${SEARCH_SCRIPT} {q})" \
        --bind "ctrl-r:reload(cat ${CANDIDATES_FILE})" \
        --bind "ctrl-o:execute-silent(${OPEN_SCRIPT} {2})" \
        | cut -f"${OUT_FIELDS}"
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
