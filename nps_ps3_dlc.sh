#!/bin/sh

# AUTHOR sigmaboy <j.sigmaboy@gmail.com>

# return codes:
# 1 user errors
# 2 no DLC available
# 4 not all links available
# 5 one or more DLC already downloaded (skipped)
# 6 one or more downloads failed
#
# note: a SerialStation family-widening lookup failure (API unreachable,
# or the Title ID has no "games" mapping) no longer aborts the script -
# it falls back to matching the exact Title ID only and continues.

# get directory where the scripts are located
SCRIPT_DIR="$(dirname "$(readlink -f "$(which "${0}")")")"

# source shared functions
. "${SCRIPT_DIR}/functions.sh"

my_usage() {
    echo ""
    echo "Usage:"
    echo "${0} \"/path/to/PS3_DLCS.tsv\" \"BCUS01234\""
}

MY_BINARIES="sed grep file curl jq fzf aria2c"
sha256_choose

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
RELATED_IDS="$(serialstation_related_title_ids "${GAME_ID}" 2>/dev/null)"
if [ ${?} -ne 0 ] || [ -z "${RELATED_IDS}" ]
then
    # serialstation_related_title_ids runs in a subshell here (command
    # substitution), so its "exit 3" only terminates that subshell - this
    # branch just means the family-widening lookup itself didn't work
    # (SerialStation unreachable, or it has no "games" mapping for this
    # Title ID - both observed in practice, independent of whether NPS's
    # own TSV actually has real rows under this exact ID). That's not
    # reason enough to give up: fall back to matching the exact Title ID
    # only, which is exactly what a plain, unresolved lookup would have
    # done anyway before this family-widening feature existed.
    >&2 echo "Could not resolve related Title IDs for \"${GAME_ID}\" via SerialStation; falling back to an exact Title ID match only."
    RELATED_IDS="${GAME_ID}"
fi
GREP_PATTERN="^($(echo "${RELATED_IDS}" | tr '\n' '|' | sed 's/|$//'))"

if ! grep -q -E "${GREP_PATTERN}" "${TSV_FILE}"
then
    >&2 echo "No DLC found for \"${GAME_ID}\" (checked its full related Title ID family)."
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

# Apply the picker's selection (if it ran) to LIST, producing the final
# set of rows to actually fetch.
if [ "${PICKER_RAN}" = true ]
then
    FILTERED_LIST="$(echo "${LIST}" | awk -F'\t' -v ids=" ${SELECTED_CONTENT_IDS} " '{ if (index(ids, " " $5 " ") > 0) print }')"
else
    FILTERED_LIST="${LIST}"
fi

# Bounded parallel fan-out: each selected row is handed to a standalone
# worker script (dispatched via xargs -P) that performs exactly what a
# single loop iteration used to do, one item per process. Workers can't
# mutate this shell's counters directly, so each writes a one-line
# status (MISSING/EXISTING/FAILED/OK) to its own file in a results
# directory, summed below once every worker has finished.
NPS_DLC_PARALLEL="${NPS_DLC_PARALLEL:-4}"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT
RESULTS_DIR="${WORKDIR}/results"
mkdir -p "${RESULTS_DIR}"

# Rows are looked up by Content ID from this file rather than passed
# through xargs directly - BSD xargs' "-I" substitution collapses
# embedded tabs to spaces when building the replacement argument, which
# silently corrupts every tab-delimited field, so only a single
# whitespace-free token (the Content ID) is ever handed through xargs.
ROWS_FILE="${WORKDIR}/rows.tsv"
echo "${FILTERED_LIST}" > "${ROWS_FILE}"

WORKER_SCRIPT="${WORKDIR}/download-item.sh"
cat > "${WORKER_SCRIPT}" <<EOF
#!/bin/sh
. "${SCRIPT_DIR}/functions.sh"
# xargs -P dispatches this as a separate process, so it doesn't inherit
# the parent script's \$SHA256 tool-selector variable - sha256_choose
# must be called again here or my_sha256 silently hashes nothing, making
# every checksum comparison a spurious mismatch.
sha256_choose

CONTENT_ID="\${1}"
ROWS_FILE="\${2}"
DESTDIR="\${3}"
RESULTS_DIR="\${4}"

ROW="\$(awk -F'\t' -v cid="\${CONTENT_ID}" '\$5 == cid { print; exit }' "\${ROWS_FILE}")"

REGION="\$(echo "\${ROW}" | cut -f1)"
NAME="\$(echo "\${ROW}" | cut -f2)"
LINK="\$(echo "\${ROW}" | cut -f3)"
RAP="\$(echo "\${ROW}" | cut -f4)"
LIST_SHA256="\$(echo "\${ROW}" | cut -f7)"

RESULT_FILE="\${RESULTS_DIR}/\${CONTENT_ID}"

if [ "\${LINK}" = "MISSING" ]
then
    >&2 echo "Download link of \"\${CONTENT_ID}\" is missing."
    echo "MISSING" > "\${RESULT_FILE}"
    exit 0
fi

# Human-readable per-item folder (today's old flat filename formula,
# now a folder name) since the pkg's own source filename is typically a
# non-human-readable CDN hash - the pkg/rap inside it keep their real
# source names instead of being renamed (rap2file sends a real
# Content-Disposition: filename=\${CONTENT_ID}.rap, confirmed live; the
# pkg CDN sends none, so its URL basename is the only real source name).
ITEM_DIR="\${DESTDIR}/dlc/\$(sanitize_filename "\${NAME}") [\${CONTENT_ID}] [\${REGION}]"
PKG_FILENAME="\$(basename "\${LINK}" | sed 's/?.*//')"
PKG_PATH="\${ITEM_DIR}/\${PKG_FILENAME}"
RAP_PATH="\${ITEM_DIR}/\${CONTENT_ID}.rap"

# The pkg's filename isn't ours to control, so "already downloaded" is
# judged by whether the item folder already has any pkg in it at all.
PKG_EXISTS=false
[ -n "\$(find "\${ITEM_DIR}" -maxdepth 1 -type f -name "*.pkg" 2>/dev/null)" ] && PKG_EXISTS=true

RAP_NEEDED=true
case "\${RAP}" in
    ""|"MISSING"|"NOT REQUIRED"|"UNLOCK/LICENSE BY DLC")
        RAP_NEEDED=false
        ;;
esac

NEEDS_DOWNLOAD=false
if [ "\${PKG_EXISTS}" = false ]
then
    NEEDS_DOWNLOAD=true
elif [ "\${RAP_NEEDED}" = true ] && [ ! -f "\${RAP_PATH}" ]
then
    NEEDS_DOWNLOAD=true
fi

if [ "\${NEEDS_DOWNLOAD}" = false ]
then
    >&2 echo "A pkg for \"\${NAME}\" [\${CONTENT_ID}] already exists in \"\${ITEM_DIR}\"."
    echo "EXISTING" > "\${RESULT_FILE}"
    exit 0
fi

if [ "\${PKG_EXISTS}" = false ]
then
    my_download_file "\${LINK}" "\${PKG_PATH}"
    if [ \${?} -ne 0 ]
    then
        >&2 echo "Download of \"\${PKG_FILENAME}\" (\${NAME}) failed."
        rm -f "\${PKG_PATH}"
        echo "FAILED" > "\${RESULT_FILE}"
        exit 0
    fi

    if [ -n "\${LIST_SHA256}" ]
    then
        FILE_SHA256="\$(my_sha256 "\${PKG_PATH}")"
        if [ "\${FILE_SHA256}" != "\${LIST_SHA256}" ]
        then
            # Interactive confirm-and-keep-or-delete isn't viable with
            # several workers running at once, so a mismatch is treated
            # as a hard failure under parallel dispatch instead.
            >&2 echo "Checksum of \"\${PKG_FILENAME}\" (\${NAME}) does not match the list - failing (no interactive prompt under parallel download)."
            echo "FAILED" > "\${RESULT_FILE}"
            exit 0
        fi
    fi
fi

if [ "\${RAP_NEEDED}" = true ] && [ ! -f "\${RAP_PATH}" ]
then
    my_download_file "https://nopaystation.com/tools/rap2file/\${CONTENT_ID}/\${RAP}" "\${RAP_PATH}"
    if [ \${?} -ne 0 ]
    then
        >&2 echo "Download of RAP for \"\${NAME}\" [\${CONTENT_ID}] failed."
        rm -f "\${RAP_PATH}"
        echo "FAILED" > "\${RESULT_FILE}"
        exit 0
    fi
fi

echo "OK" > "\${RESULT_FILE}"
EOF
chmod +x "${WORKER_SCRIPT}"

mkdir -p "${DESTDIR}/dlc"

cut -f5 "${ROWS_FILE}" | xargs -I{} -P "${NPS_DLC_PARALLEL}" "${WORKER_SCRIPT}" "{}" "${ROWS_FILE}" "${DESTDIR}" "${RESULTS_DIR}"

for RESULT_FILE in "${RESULTS_DIR}"/*
do
    [ -e "${RESULT_FILE}" ] || continue
    case "$(cat "${RESULT_FILE}")" in
        MISSING) MISSING_COUNT=$((MISSING_COUNT + 1)) ;;
        EXISTING) EXISTING_COUNT=$((EXISTING_COUNT + 1)) ;;
        FAILED) FAILED_COUNT=$((FAILED_COUNT + 1)) ;;
    esac
done

rm -rf "${WORKDIR}"
trap - EXIT

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
