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
    echo ""
    echo "\"--nps-dir\" is always required. Omit \"--title-id\" to open an"
    echo "interactive title search (supports selecting multiple games) instead."
    echo ""
    echo "Usage:"
    echo "${0} --nps-dir </path/to/nps/directory> [--title-id \"<TITLE ID> [<TITLE ID> ...]\"]"
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

if [ -z "${TITLE_ID_ARG}" ]
then
    TITLE_ID_ARG="$(ps3_typeahead_search "${NPS_DIR}/PS3_GAMES.tsv" "1" | tr '\n' ' ')"
    if [ -z "$(echo "${TITLE_ID_ARG}" | tr -d '[:space:]')" ]
    then
        echo "No games selected."
        exit 1
    fi
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

for TITLE_ID in ${TITLE_IDS}
do
    echo "--------------------------------------------"
    echo "Downloading and packing \"${TITLE_ID}\"..."

    ### Download the chosen game
    nps_ps3.sh "${NPS_DIR}/PS3_GAMES.tsv" "${TITLE_ID}"
    GAME_STATUS=${?}

    if [ ${GAME_STATUS} -eq 5 ]
    then
        echo ""
        echo "Game already downloaded, continuing to DLC step."
    elif [ ${GAME_STATUS} -ne 0 ]
    then
        echo ""
        echo "Game cannot be downloaded. Still checking for DLC for \"${TITLE_ID}\"."
    fi

    ### Get name of the game folder from generated txt created via nps_ps3.sh,
    ### or fall back to a DLC-only folder name when the Title ID has no
    ### PS3_GAMES.tsv row at all (nps_ps3.sh never wrote the txt file).
    if [ -f "${TITLE_ID}.txt" ]
    then
        FOLDER_NAME="$(cat "${TITLE_ID}.txt")"
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

    ### Download available DLC
    DESTDIR="${FOLDER_NAME}" nps_ps3_dlc.sh "${NPS_DIR}/PS3_DLCS.tsv" "${TITLE_ID}"
    DLC_STATUS=${?}

    ### remove temporary game name file
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

    if [ "${GAME_OK}" = true ] || [ "${DLC_OK}" = true ]
    then
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
done

echo "--------------------------------------------"
echo "Finished: ${SUCCESS_COUNT} succeeded, ${FAIL_COUNT} failed."

if [ ${FAIL_COUNT} -gt 0 ]
then
    exit 1
fi
exit 0
