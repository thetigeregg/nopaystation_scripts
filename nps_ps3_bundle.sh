#!/bin/sh

# AUTHOR sigmaboy <j.sigmaboy@gmail.com>

# get directory where the scripts are located
SCRIPT_DIR="$(dirname "$(readlink -f "$(which "${0}")")")"

# source shared functions
. "${SCRIPT_DIR}/functions.sh"

### usage function
my_usage(){
    echo ""
    echo "Parameters:"
    echo "--nps-dir|-d <DIR>               path to the directory containing the tsv files"
    echo "--title-id|-t <TITLE ID(S)>      one or more title IDs, quoted and space-separated"
    echo "--all-dlc|-a                     download every available DLC without prompting"
    echo "--all-updates|-u                 download every available update version without prompting"
    echo ""
    echo "\"--nps-dir\" is always required. Omit \"--title-id\" to open an"
    echo "interactive title search (supports selecting multiple games) instead."
    echo "By default you'll be asked which DLC/update version to download per"
    echo "title (all/latest pre-selected); \"--all-dlc\"/\"--all-updates\" skip"
    echo "those prompts for batch runs. Game updates come live from Sony's own"
    echo "servers, independent of the *.tsv files, so they're always attempted."
    echo ""
    echo "Usage:"
    echo "${0} --nps-dir </path/to/nps/directory> [--title-id \"<TITLE ID> [<TITLE ID> ...]\"] [--all-dlc] [--all-updates]"
}

### check if nps tsv file directory exists
test_nps_dir() {
    local NPS_DIR="${1}"
    if [ ! -d "${NPS_DIR}" ]
    then
        echo "Directory containing *.tsv files missing (\"${NPS_DIR}\"). Check your path parameter."
        my_usage
        exit 1
    fi
}

while [ ${#} -ge 1 ]
do
    opt=${1}
    shift
    case ${opt} in
        -t|--title-id)
            test -n "${1}"
            exit_if_fail "\"-t\" used without <TITLE ID>"
            TITLE_ID_ARG="${1}"
            shift
            ;;
        -d|--nps-dir)
            test -n "${1}"
            exit_if_fail "\"-d\" used without directory path argument used"
            test_nps_dir "${1}"
            NPS_DIR="${1}"
            shift
            ;;
        -a|--all-dlc)
            NPS_DLC_AUTO_ALL=1
            ;;
        -u|--all-updates)
            NPS_UPDATE_AUTO_ALL=1
            ;;
        *)
            echo "Invalid parameter used."
            my_usage
            echo ""
            exit 1
            ;;
    esac
done

# check if necessary binaries are available
MY_BINARIES="sed grep file curl jq fzf"
check_binaries "${MY_BINARIES}"

if [ -z "${NPS_DIR}" ]
then
    echo "ERROR:"
    echo "<NPS DIR> is missing."
    echo 'Use "-d <NPS DIR>" parameter'
    exit 1
fi

### check if nps tsv file directory exists
if [ ! -d "${NPS_DIR}" ]
then
    echo "Directory containing *.tsv files missing (\"${NPS_DIR}\"). Check your path parameter."
    my_usage
    exit 1
fi

### check if the tsv files are available to call download scripts
tsv_files="PS3_GAMES.tsv PS3_DLCS.tsv"
for tsv_file in $tsv_files
do
    if [ ! -f "${NPS_DIR}/${tsv_file}" ]
    then
        echo "*.tsv file \"${tsv_file}\" in path \"${NPS_DIR}\" missing."
        exit 1
    fi
done

# Title IDs picked via the SerialStation search mode (ctrl-s) get their
# game-download step skipped later on - collected here while parsing the
# search results. IDs supplied directly via "-t" never populate this list.
API_TITLE_IDS=""

if [ -z "${TITLE_ID_ARG}" ]
then
    SEARCH_RESULT="$(ps3_typeahead_search "${NPS_DIR}/PS3_GAMES.tsv" "1")"
    if [ -z "$(echo "${SEARCH_RESULT}" | tr -d '[:space:]')" ]
    then
        echo "No games selected."
        exit 1
    fi

    TITLE_ID_ARG=""
    while IFS="$(printf '\t')" read -r SRC ID
    do
        [ -z "${ID}" ] && continue
        TITLE_ID_ARG="${TITLE_ID_ARG} ${ID}"
        if [ "${SRC}" = "api" ]
        then
            API_TITLE_IDS="${API_TITLE_IDS} ${ID}"
        fi
    done <<EOF
${SEARCH_RESULT}
EOF
fi

# split and validate every title ID up front, before any downloads start
TITLE_IDS=""
for id in ${TITLE_ID_ARG}
do
    check_valid_ps3_id "${id}"
    id=$(echo "${id}" | tr '[:lower:]' '[:upper:]')
    TITLE_IDS="${TITLE_IDS} ${id}"
done

SUCCESS_COUNT=0
FAIL_COUNT=0
NOTHING_FOUND_COUNT=0

for TITLE_ID in ${TITLE_IDS}
do
    echo "--------------------------------------------"
    echo "Downloading and packing \"${TITLE_ID}\"..."

    ### Titles found via SerialStation search never get a game-download
    ### attempt - that search mode exists specifically for titles that may
    ### have no PS3_GAMES.tsv row at all, so go straight to DLC.
    IS_API_SOURCED=false
    case " ${API_TITLE_IDS} " in
        *" ${TITLE_ID} "*) IS_API_SOURCED=true ;;
    esac

    ### Precompute the folder name up front - identical formula to what
    ### nps_ps3.sh derives internally - so it's known before the game
    ### download (which may run in the background) has finished, or even
    ### started. When the Title ID has no PS3_GAMES.tsv row at all (API-
    ### sourced titles only), fall back to a DLC-only folder name via a
    ### best-effort SerialStation name lookup.
    GAME_MATCH="$(grep "^${TITLE_ID}" "${NPS_DIR}/PS3_GAMES.tsv" 2>/dev/null | tr -d '\r' | head -n1)"
    if [ -n "${GAME_MATCH}" ]
    then
        GAME_REGION="$(echo "${GAME_MATCH}" | cut -f2)"
        GAME_NAME="$(echo "${GAME_MATCH}" | cut -f3)"
        FOLDER_NAME="$(sanitize_filename "${GAME_NAME}") [${TITLE_ID}] [${GAME_REGION}]"
    else
        # Best-effort, non-fatal lookup: unlike serialstation_fetch (which
        # exit()s loudly on failure), a lookup failure here must not abort
        # the run - we still want to try the DLC step either way.
        NAME="$(curl -fsS "${SERIALSTATION_API_BASE}/title-ids/${TITLE_ID}" 2>/dev/null | jq -r '.name // empty' 2>/dev/null)"
        if [ -n "${NAME}" ]
        then
            FOLDER_NAME="$(sanitize_filename "${NAME}") [${TITLE_ID}]"
        else
            echo "Could not fetch a display name for \"${TITLE_ID}\"; using the bare Title ID for the DLC folder."
            FOLDER_NAME="${TITLE_ID}"
        fi
    fi

    GAME_PID=""
    if [ "${IS_API_SOURCED}" = true ] && [ -z "${GAME_MATCH}" ]
    then
        # Only skip the game download when the Title ID picked via
        # SerialStation search genuinely has no PS3_GAMES.tsv row - it's
        # possible for a title to be found through that search mode and
        # still have a real local row (e.g. it just wasn't surfaced by
        # the local-results search text), in which case the download
        # should proceed as normal.
        echo ""
        echo "\"${TITLE_ID}\" was found via SerialStation search - checking DLC only."
        GAME_STATUS=1
    else
        ### Kick off the game download in the background so it can proceed
        ### concurrently with the DLC step below. stdin is severed
        ### (/dev/null) so it never contends with nps_ps3_dlc.sh's
        ### interactive picker for the terminal, and stdout/stderr are
        ### captured to a log rather than interleaved live.
        GAME_LOG="$(mktemp)"
        nps_ps3.sh "${NPS_DIR}/PS3_GAMES.tsv" "${TITLE_ID}" < /dev/null > "${GAME_LOG}" 2>&1 &
        GAME_PID=${!}

        # The game's own output is only printed in full after it finishes
        # (see below) so it doesn't interleave with the DLC step's picker -
        # but that leaves no visible sign it's progressing at all for
        # anything but a short download, so poll its log for aria2c's
        # periodic "(NN%)" summary line and echo just that line while it
        # runs. aria2c only emits those summaries periodically when its
        # output isn't a tty (true here, since stdout is redirected to
        # GAME_LOG) - my_download_file sets --summary-interval=5 so they
        # show up often enough to be useful.
        ( while kill -0 "${GAME_PID}" 2>/dev/null
          do
              sleep 5
              LAST_PROGRESS="$(grep -E '\([0-9]+%\)' "${GAME_LOG}" 2>/dev/null | tail -n1)"
              [ -n "${LAST_PROGRESS}" ] && echo "[game] ${LAST_PROGRESS}"
          done ) &
        MONITOR_PID=${!}
    fi

    ### Kick off the update download in the background too - unlike the
    ### game/DLC, updates come live from Sony's own servers and don't
    ### depend on PS3_GAMES.tsv/PS3_DLCS.tsv or SerialStation at all, so
    ### they're attempted for every Title ID unconditionally, regardless
    ### of IS_API_SOURCED/GAME_MATCH. No interactive picker to worry about
    ### here (nps_ps3_update.sh auto-bypasses to latest-only, or every
    ### version with NPS_UPDATE_AUTO_ALL=1, whenever stdin isn't a tty),
    ### so this can safely run fully backgrounded alongside the game.
    UPDATE_LOG="$(mktemp)"
    DESTDIR="${FOLDER_NAME}" NPS_UPDATE_AUTO_ALL="${NPS_UPDATE_AUTO_ALL}" \
        nps_ps3_update.sh "${TITLE_ID}" < /dev/null > "${UPDATE_LOG}" 2>&1 &
    UPDATE_PID=${!}

    ### Download available DLC (runs in the foreground, retaining full
    ### interactive control, while the game and updates download underneath)
    DESTDIR="${FOLDER_NAME}" NPS_DLC_AUTO_ALL="${NPS_DLC_AUTO_ALL}" nps_ps3_dlc.sh "${NPS_DIR}/PS3_DLCS.tsv" "${TITLE_ID}"
    DLC_STATUS=${?}

    if [ -n "${GAME_PID}" ]
    then
        wait "${GAME_PID}"
        GAME_STATUS=${?}
        kill "${MONITOR_PID}" 2>/dev/null
        wait "${MONITOR_PID}" 2>/dev/null
        cat "${GAME_LOG}"
        rm -f "${GAME_LOG}"

        if [ ${GAME_STATUS} -eq 5 ]
        then
            echo ""
            echo "Game already downloaded, continuing to DLC step."
        elif [ ${GAME_STATUS} -ne 0 ]
        then
            echo ""
            echo "Game cannot be downloaded. Still checking for DLC for \"${TITLE_ID}\"."
        fi
    fi

    wait "${UPDATE_PID}"
    UPDATE_STATUS=${?}
    cat "${UPDATE_LOG}"
    rm -f "${UPDATE_LOG}"

    ### remove temporary game name file (written by nps_ps3.sh)
    rm -f "${TITLE_ID}.txt"

    ### Run post scripts
    if [ -x ./nps_ps3_bundle_post.sh ]
    then
        ./nps_ps3_bundle_post.sh "${FOLDER_NAME}"
    fi

    # A title counts as successful if either the game or its DLC actually
    # produced something - nps_ps3_dlc.sh's exit code alone can't tell
    # "partially missing but some downloaded" from "nothing downloaded",
    # so check the DLC output directory directly.
    GAME_OK=false
    if [ ${GAME_STATUS} -eq 0 ] || [ ${GAME_STATUS} -eq 5 ]
    then
        GAME_OK=true
    fi

    DLC_OK=false
    if [ -d "${FOLDER_NAME}/dlc" ] && [ -n "$(find "${FOLDER_NAME}/dlc" -maxdepth 1 -type f -name "*.pkg" 2>/dev/null)" ]
    then
        DLC_OK=true
    fi

    UPDATE_OK=false
    if [ -d "${FOLDER_NAME}/updates" ] && [ -n "$(find "${FOLDER_NAME}/updates" -maxdepth 1 -type f -name "*.pkg" 2>/dev/null)" ]
    then
        UPDATE_OK=true
    fi

    if [ "${GAME_OK}" = true ] || [ "${DLC_OK}" = true ] || [ "${UPDATE_OK}" = true ]
    then
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    elif [ "${IS_API_SOURCED}" = true ]
    then
        # A SerialStation search is speculative - checking whether an ID
        # NPS doesn't already have locally happens to have anything.
        # Coming up empty is a legitimate outcome of that search, not an
        # error, so it's tracked separately rather than as a failure.
        echo ""
        echo "Nothing found for \"${TITLE_ID}\" via SerialStation search (not counted as a failure)."
        NOTHING_FOUND_COUNT=$((NOTHING_FOUND_COUNT + 1))
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
done

echo "--------------------------------------------"
echo "Finished: ${SUCCESS_COUNT} succeeded, ${FAIL_COUNT} failed, ${NOTHING_FOUND_COUNT} found nothing via search."

if [ ${FAIL_COUNT} -gt 0 ]
then
    exit 1
fi
exit 0
