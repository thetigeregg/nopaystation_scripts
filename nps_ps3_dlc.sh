#!/bin/sh

# AUTHOR sigmaboy <j.sigmaboy@gmail.com>

# return codes:
# 1 user errors
# 2 no DLC available
# 4 not all links available
# 5 one or more DLC already downloaded (skipped)

# get directory where the scripts are located
SCRIPT_DIR="$(dirname "$(readlink -f "$(which "${0}")")")"

# source shared functions
. "${SCRIPT_DIR}/functions.sh"

my_usage() {
    echo ""
    echo "Usage:"
    echo "${0} \"/path/to/PS3_DLCS.tsv\" \"BCUS01234\""
}

MY_BINARIES="sed grep file"
sha256_choose; downloader_choose

check_binaries "${MY_BINARIES}"

# Get variables from script parameters
TSV_FILE="${1}"
GAME_ID="${2}"

if [ ! -f "${TSV_FILE}" ]
then
    echo "No TSV file found."
    my_usage
    exit 1
fi
if [ -z "${GAME_ID}" ]
then
    echo "No game ID found."
    my_usage
    exit 1
fi

check_valid_ps3_id "${GAME_ID}"
# TSV lookups are case-sensitive, but check_valid_ps3_id accepts lowercase, so normalize
GAME_ID=$(echo "${GAME_ID}" | tr '[:lower:]' '[:upper:]')

# make DESTDIR overridable
if [ -z "${DESTDIR}" ]
then
    DESTDIR="${GAME_ID}"
fi

if ! grep -q "^${GAME_ID}" "${TSV_FILE}"
then
    exit 2
fi

LIST=$(grep "^${GAME_ID}" "${TSV_FILE}" | tr -d '\r' | cut -f"3,4,5,6,10")
LINE_COUNT=$(echo "${LIST}" | wc -l | tr -d ' ')

MISSING_COUNT=0
EXISTING_COUNT=0

i=1
while [ "${i}" -le "${LINE_COUNT}" ]
do
    ROW=$(echo "${LIST}" | sed -n "${i}p")
    i=$((i + 1))

    NAME=$(echo "${ROW}" | cut -f1)
    LINK=$(echo "${ROW}" | cut -f2)
    RAP=$(echo "${ROW}" | cut -f3)
    CONTENT_ID=$(echo "${ROW}" | cut -f4)
    LIST_SHA256=$(echo "${ROW}" | cut -f5)

    if [ "${LINK}" = "MISSING" ]
    then
        >&2 echo "Download link of \"${CONTENT_ID}\" is missing."
        MISSING_COUNT=$((MISSING_COUNT + 1))
        continue
    fi

    FILE_NAME="$(sanitize_filename "${NAME}") [${CONTENT_ID}]"

    if [ -f "${DESTDIR}_dlc/${FILE_NAME}.pkg" ]
    then
        >&2 echo "File \"${FILE_NAME}.pkg\" already exists."
        EXISTING_COUNT=$((EXISTING_COUNT + 1))
        continue
    fi

    mkdir -p "${DESTDIR}_dlc"

    my_download_file "${LINK}" "${DESTDIR}_dlc/${FILE_NAME}.pkg"
    if [ -n "${LIST_SHA256}" ]
    then
        FILE_SHA256="$(my_sha256 "${DESTDIR}_dlc/${FILE_NAME}.pkg")"
        compare_checksum "${LIST_SHA256}" "${FILE_SHA256}"
    fi

    case "${RAP}" in
        ""|"MISSING"|"NOT REQUIRED"|"UNLOCK/LICENSE BY DLC")
            ;;
        *)
            my_download_file "https://nopaystation.com/tools/rap2file/${CONTENT_ID}/${RAP}" "${DESTDIR}_dlc/${FILE_NAME}.rap"
            ;;
    esac
done

if [ "${MISSING_COUNT}" -gt 0 ]
then
    exit 4
elif [ "${EXISTING_COUNT}" -gt 0 ]
then
    exit 5
else
    exit 0
fi
