#!/bin/sh

# AUTHOR sigmaboy <j.sigmaboy@gmail.com>

# return codes:
# 1 user errors
# 3 game is only available physically
# 4 link missing.
# 5 game pkg already exists
# 6 download failed

# get directory where the scripts are located
SCRIPT_DIR="$(dirname "$(readlink -f "$(which "${0}")")")"

# source shared functions
. "${SCRIPT_DIR}/functions.sh"

my_usage() {
    echo ""
    echo "Usage:"
    echo "${0} \"/path/to/PS3_GAMES.tsv\" [\"BCUS01234\"]"
    echo ""
    echo "Omit the Title ID to open an interactive title search instead."
}

MY_BINARIES="sed grep file fzf aria2c"
sha256_choose

check_binaries "${MY_BINARIES}"

# Get variables from script parameters
TSV_FILE="${1}"
TITLE_ID="${2}"


if [ ! -f "${TSV_FILE}" ]
then
    echo "No TSV file found."
    my_usage
    exit 1
fi

if [ -z "${TITLE_ID}" ]
then
    TITLE_ID="$(ps3_typeahead_search "${TSV_FILE}" "")"
    if [ -z "${TITLE_ID}" ]
    then
        echo "No game selected."
        exit 1
    fi
fi

check_valid_ps3_id "${TITLE_ID}"
# TSV lookups are case-sensitive, but check_valid_ps3_id accepts lowercase, so normalize
TITLE_ID=$(echo "${TITLE_ID}" | tr '[:lower:]' '[:upper:]')

# check if MEDIA ID is found in download list
MATCHES=$(grep "^${TITLE_ID}" "${TSV_FILE}" | tr -d '\r')

if [ -z "${MATCHES}" ]
then
    echo "ERROR:"
    echo "Media ID is not found in your *.tsv file"
    echo "Check your input for a valid media ID"
    echo "Search on: \"https://renascene.com/ps3/\" for"
    echo "Media IDs or simple open the *.tsv with your Office Suite."
    exit 1
fi

# some PS3 titles reuse the same title ID across multiple region rows
MATCH_COUNT=$(echo "${MATCHES}" | wc -l | tr -d ' ')

if [ "${MATCH_COUNT}" -eq 1 ]
then
    SELECTED_LINE="${MATCHES}"
    REGION=$(echo "${SELECTED_LINE}" | cut -f2)
    echo "Region: ${REGION}"
else
    echo "Multiple regions found for \"${TITLE_ID}\":"
    i=1
    while [ "${i}" -le "${MATCH_COUNT}" ]
    do
        LINE=$(echo "${MATCHES}" | sed -n "${i}p")
        REGION=$(echo "${LINE}" | cut -f2)
        NAME=$(echo "${LINE}" | cut -f3)
        echo "${i}) ${REGION} - ${NAME}"
        i=$((i + 1))
    done

    while true
    do
        echo "Choose a region (1-${MATCH_COUNT}):"
        if ! read CHOICE
        then
            # EOF on stdin (e.g. running backgrounded/non-interactively
            # with stdin redirected from /dev/null) - fail cleanly
            # instead of spinning forever on immediate EOF reads.
            echo "No input available to choose a region (running non-interactively?)."
            exit 1
        fi
        case "${CHOICE}" in
            ''|*[!0-9]*)
                echo "Invalid selection."
                continue
                ;;
        esac
        if [ "${CHOICE}" -ge 1 ] && [ "${CHOICE}" -le "${MATCH_COUNT}" ]
        then
            break
        fi
        echo "Invalid selection."
    done

    SELECTED_LINE=$(echo "${MATCHES}" | sed -n "${CHOICE}p")
fi

# recompute from the finally-selected line, not whatever the display loop last set
REGION=$(echo "${SELECTED_LINE}" | cut -f2)
NAME=$(echo "${SELECTED_LINE}" | cut -f3)

FOLDER_NAME="$(sanitize_filename "${NAME}") [${TITLE_ID}] [${REGION}]"
echo "${FOLDER_NAME}" > "${TITLE_ID}.txt"

# get link, rap filename, content id and sha256sum
LIST=$(echo "${SELECTED_LINE}" | cut -f"1,4,5,6,10")

# save those in separate variables
LINK=$(echo "${LIST}" | cut -f2)
RAP=$(echo "${LIST}" | cut -f3)
CONTENT_ID=$(echo "${LIST}" | cut -f4)
LIST_SHA256=$(echo "${LIST}" | cut -f5)

if [ "${LINK}" = "MISSING" ]
then
    echo "Download link of \"${TITLE_ID}\" is missing."
    echo "Cannot proceed."
    exit 4
elif [ "${LINK}" = "CART ONLY" ]
then
    echo "\"${TITLE_ID}\" is only available via cartridge"
    exit 3
else
    PKG_PATH="${FOLDER_NAME}/${FOLDER_NAME}.pkg"
    RAP_PATH="${FOLDER_NAME}/${FOLDER_NAME}.rap"

    PKG_EXISTS=false
    [ -f "${PKG_PATH}" ] && PKG_EXISTS=true

    RAP_NEEDED=true
    case "${RAP}" in
        ""|"MISSING"|"NOT REQUIRED"|"UNLOCK/LICENSE BY DLC")
            RAP_NEEDED=false
            ;;
    esac

    NEEDS_DOWNLOAD=false
    if [ "${PKG_EXISTS}" = false ]
    then
        NEEDS_DOWNLOAD=true
    elif [ "${RAP_NEEDED}" = true ] && [ ! -f "${RAP_PATH}" ]
    then
        NEEDS_DOWNLOAD=true
    fi

    if [ "${NEEDS_DOWNLOAD}" = false ]
    then
        # print this to stderr
        >&2 echo "File \"${PKG_PATH}\" already exists."
        exit 5
    fi

    mkdir -p "${FOLDER_NAME}"

    if [ "${PKG_EXISTS}" = false ]
    then
        my_download_file "${LINK}" "${PKG_PATH}"
        if [ ${?} -ne 0 ]
        then
            >&2 echo "Download of \"${PKG_PATH}\" failed."
            rm -f "${PKG_PATH}"
            exit 6
        fi

        if [ -n "${LIST_SHA256}" ]
        then
            FILE_SHA256="$(my_sha256 "${PKG_PATH}")"
            compare_checksum "${LIST_SHA256}" "${FILE_SHA256}"
        fi
    fi

    if [ "${RAP_NEEDED}" = true ] && [ ! -f "${RAP_PATH}" ]
    then
        my_download_file "https://nopaystation.com/tools/rap2file/${CONTENT_ID}/${RAP}" "${RAP_PATH}"
        if [ ${?} -ne 0 ]
        then
            >&2 echo "Download of RAP for \"${TITLE_ID}\" failed."
            rm -f "${RAP_PATH}"
            exit 6
        fi
    fi
fi
exit 0
