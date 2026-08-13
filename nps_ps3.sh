#!/bin/sh

# AUTHOR sigmaboy <j.sigmaboy@gmail.com>

# return codes:
# 1 user errors
# 3 game is only available physically
# 4 link missing.
# 5 game pkg already exists

# get directory where the scripts are located
SCRIPT_DIR="$(dirname "$(readlink -f "$(which "${0}")")")"

# source shared functions
. "${SCRIPT_DIR}/functions.sh"

my_usage() {
    echo ""
    echo "Usage:"
    echo "${0} \"/path/to/PS3_GAMES.tsv\" \"BCUS01234\""
}

MY_BINARIES="sed grep file"
sha256_choose; downloader_choose

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
    echo "No game ID found."
    my_usage
    exit 1
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
        read CHOICE
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
    if [ -f "${TITLE_ID}.pkg" ]
    then
        # print this to stderr
        >&2 echo "File \"${TITLE_ID}.pkg\" already exists."
        exit 5
    else
        my_download_file "${LINK}" "${TITLE_ID}.pkg"
        if [ -n "${LIST_SHA256}" ]
        then
            FILE_SHA256="$(my_sha256 "${TITLE_ID}.pkg")"
            compare_checksum "${LIST_SHA256}" "${FILE_SHA256}"
        fi

        case "${RAP}" in
            ""|"MISSING"|"NOT REQUIRED"|"UNLOCK/LICENSE BY DLC")
                ;;
            *)
                my_download_file "https://nopaystation.com/tools/rap2file/${CONTENT_ID}/${RAP}" "${TITLE_ID}.rap"
                ;;
        esac
    fi
fi
exit 0
