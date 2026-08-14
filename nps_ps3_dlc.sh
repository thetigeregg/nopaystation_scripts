#!/bin/sh

# AUTHOR sigmaboy <j.sigmaboy@gmail.com>

# return codes:
# 1 user errors
# 2 no DLC available
# 3 SerialStation lookup failed (API unreachable or Title ID unmapped)
# 4 not all links available
# 5 one or more DLC already downloaded (skipped)
# 6 one or more downloads failed

# get directory where the scripts are located
SCRIPT_DIR="$(dirname "$(readlink -f "$(which "${0}")")")"

# source shared functions
. "${SCRIPT_DIR}/functions.sh"

my_usage() {
    echo ""
    echo "Usage:"
    echo "${0} \"/path/to/PS3_DLCS.tsv\" \"BCUS01234\""
}

MY_BINARIES="sed grep file curl jq fzf"
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

# A game can have several Title IDs (physical/digital, per region, re-releases),
# and DLC is often filed under a different one than the game itself was downloaded
# with. Resolve the full family of related Title IDs via SerialStation so DLC
# filed under a sibling ID is still found.
NPS_DIR="$(dirname "${TSV_FILE}")"
RELATED_IDS="$(serialstation_related_title_ids "${GAME_ID}")"
if [ ${?} -ne 0 ]
then
    # serialstation_related_title_ids runs in a subshell here (command
    # substitution), so its "exit 3" only terminates that subshell -
    # propagate the failure explicitly.
    exit 3
fi
GREP_PATTERN="^($(echo "${RELATED_IDS}" | tr '\n' '|' | sed 's/|$//'))"

if ! grep -q -E "${GREP_PATTERN}" "${TSV_FILE}"
then
    exit 2
fi

# Best-effort guess at the game's own region from its Title ID, matching
# PS3_DLCS.tsv's own short region-code vocabulary (confirmed: only ASIA,
# EU, JP, US appear there) - distinct from functions.sh's region(), which
# outputs display words like "Europe" for the unrelated SerialStation
# search UI.
ps3_dlc_region_guess() {
    case "$(echo "${1}" | cut -c3)" in
        A) echo "ASIA" ;;
        E) echo "EU" ;;
        J|P) echo "JP" ;;
        U) echo "US" ;;
        *) echo "" ;;
    esac
}

LIST=$(grep -E "${GREP_PATTERN}" "${TSV_FILE}" | tr -d '\r' | cut -f"2,3,4,5,6,9,10")
LINE_COUNT=$(echo "${LIST}" | wc -l | tr -d ' ')
DISTINCT_REGIONS="$(echo "${LIST}" | cut -f1 | sort -u)"

# Let the user pick which of the matched DLC to actually download, with
# everything pre-selected by default so Enter alone reproduces
# download-everything (today's behavior). Skipped (defaults to
# "everything") when NPS_DLC_AUTO_ALL=1 is set, or when not running
# interactively, so scripted/batch usage never hangs on fzf input.
SELECTED_CONTENT_IDS=""
PICKER_RAN=false
CHOSEN_REGION="ALL"
if [ "${NPS_DLC_AUTO_ALL}" != "1" ] && [ -t 0 ] && [ -t 1 ]
then
    PICKER_RAN=true

    # When DLC spans more than one region, ask which region to start
    # from before showing individual DLC - the game's own guessed region
    # (if present) is offered first, with an explicit "all regions"
    # escape hatch to fall back to today's show-everything behavior.
    if [ "$(echo "${DISTINCT_REGIONS}" | wc -l | tr -d ' ')" -gt 1 ]
    then
        GUESSED_REGION="$(ps3_dlc_region_guess "${GAME_ID}")"
        REGION_CANDIDATES=""
        if [ -n "${GUESSED_REGION}" ] && echo "${DISTINCT_REGIONS}" | grep -qx "${GUESSED_REGION}"
        then
            REGION_CANDIDATES="${GUESSED_REGION}	${GUESSED_REGION} (game's region)"
        fi
        REGION_CANDIDATES="${REGION_CANDIDATES}
$(echo "${DISTINCT_REGIONS}" | grep -vx "${GUESSED_REGION}" | awk '{printf "%s\t%s\n", $0, $0}')
ALL	All regions - show everything"

        CHOSEN_REGION="$(echo "${REGION_CANDIDATES}" | awk 'NF' | fzf \
            --height=90% --border --prompt="Select a region> " \
            --header="enter:confirm  esc:download none" \
            --delimiter="$(printf '\t')" --with-nth=2 \
            | cut -f1)"

        if [ -z "${CHOSEN_REGION}" ]
        then
            exit 2
        fi
    fi

    # human_size() is a shell function (not awk), so build the candidate
    # list with a plain read loop rather than awk.
    DLC_CANDIDATES="$(echo "${LIST}" | while IFS="$(printf '\t')" read -r REGION NAME LINK RAP CONTENT_ID SIZE SHA
    do
        [ -z "${CONTENT_ID}" ] && continue
        if [ "${CHOSEN_REGION}" != "ALL" ] && [ "${REGION}" != "${CHOSEN_REGION}" ]
        then
            continue
        fi
        DISPLAY_NAME="${NAME}"
        if [ "${LINK}" = "MISSING" ]
        then
            DISPLAY_NAME="${DISPLAY_NAME} [NO LINK]"
        fi
        printf "%s\t%-7s %-8s %s\n" "${CONTENT_ID}" "${REGION}" "$(human_size "${SIZE}")" "${DISPLAY_NAME}"
    done)"

    # Older fzf builds (e.g. the version apt installs on Debian bullseye)
    # don't support the "load" lifecycle-event bind at all and abort
    # immediately with "unsupported key: load" rather than launching -
    # probe for it non-interactively first so this degrades gracefully
    # instead of crashing on those builds.
    SELECT_ALL_BIND="--bind load:select-all"
    FZF_HEADER="enter:confirm selected  tab:toggle  esc:download none"
    if printf 'x\n' | fzf --bind load:select-all --filter '' 2>&1 >/dev/null | grep -q "unsupported key"
    then
        SELECT_ALL_BIND=""
        FZF_HEADER="ctrl-a:select all  ${FZF_HEADER}"
    fi

    SELECTED_CONTENT_IDS="$(echo "${DLC_CANDIDATES}" | fzf --multi ${SELECT_ALL_BIND} --bind ctrl-a:select-all \
        --delimiter="$(printf '\t')" --with-nth=2.. \
        --height=90% --border --prompt="Select DLC to download> " \
        --header="${FZF_HEADER}" \
        | cut -f1 | tr '\n' ' ')"

    # Esc (or deselecting everything) means "download none" - every row
    # would just get filtered out of the loop below anyway, which without
    # this check falls through to the final "else exit 0" (meant for a
    # fully successful run), wrongly conflating "declined" with "success".
    if [ -z "$(echo "${SELECTED_CONTENT_IDS}" | tr -d '[:space:]')" ]
    then
        exit 2
    fi
fi

MISSING_COUNT=0
EXISTING_COUNT=0
FAILED_COUNT=0

i=1
while [ "${i}" -le "${LINE_COUNT}" ]
do
    ROW=$(echo "${LIST}" | sed -n "${i}p")
    i=$((i + 1))

    REGION=$(echo "${ROW}" | cut -f1)
    NAME=$(echo "${ROW}" | cut -f2)
    LINK=$(echo "${ROW}" | cut -f3)
    RAP=$(echo "${ROW}" | cut -f4)
    CONTENT_ID=$(echo "${ROW}" | cut -f5)
    LIST_SHA256=$(echo "${ROW}" | cut -f7)

    if [ "${PICKER_RAN}" = true ]
    then
        case " ${SELECTED_CONTENT_IDS} " in
            *" ${CONTENT_ID} "*) ;;
            *) continue ;;
        esac
    fi

    if [ "${LINK}" = "MISSING" ]
    then
        >&2 echo "Download link of \"${CONTENT_ID}\" is missing."
        MISSING_COUNT=$((MISSING_COUNT + 1))
        continue
    fi

    FILE_NAME="$(sanitize_filename "${NAME}") [${CONTENT_ID}] [${REGION}]"
    PKG_PATH="${DESTDIR}/dlc/${FILE_NAME}.pkg"
    RAP_PATH="${DESTDIR}/dlc/${FILE_NAME}.rap"

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
        >&2 echo "File \"${FILE_NAME}.pkg\" already exists."
        EXISTING_COUNT=$((EXISTING_COUNT + 1))
        continue
    fi

    mkdir -p "${DESTDIR}/dlc"

    if [ "${PKG_EXISTS}" = false ]
    then
        my_download_file "${LINK}" "${PKG_PATH}"
        if [ ${?} -ne 0 ]
        then
            >&2 echo "Download of \"${FILE_NAME}.pkg\" failed."
            rm -f "${PKG_PATH}"
            FAILED_COUNT=$((FAILED_COUNT + 1))
            continue
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
            >&2 echo "Download of RAP for \"${FILE_NAME}\" failed."
            rm -f "${RAP_PATH}"
            FAILED_COUNT=$((FAILED_COUNT + 1))
        fi
    fi
done

if [ "${FAILED_COUNT}" -gt 0 ]
then
    exit 6
elif [ "${MISSING_COUNT}" -gt 0 ]
then
    exit 4
elif [ "${EXISTING_COUNT}" -gt 0 ]
then
    exit 5
else
    exit 0
fi
