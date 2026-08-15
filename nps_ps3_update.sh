#!/bin/sh

# Downloads PS3 game updates directly from Sony's own update servers -
# this data isn't part of NoPayStation's TSV dumps at all, so unlike
# nps_ps3.sh/nps_ps3_dlc.sh this script takes no TSV file argument.
# Protocol ported from rusty-psn (https://github.com/RainbowCookie32/rusty-psn, MIT).

# return codes:
# 1 user errors
# 2 no updates available
# 5 all requested update versions already downloaded (skipped)
# 6 one or more downloads failed

# get directory where the scripts are located
SCRIPT_DIR="$(dirname "$(readlink -f "$(which "${0}")")")"

# source shared functions
. "${SCRIPT_DIR}/functions.sh"

my_usage() {
    echo ""
    echo "Usage:"
    echo "${0} \"BCUS01234\""
    echo ""
    echo "Set NPS_UPDATE_AUTO_ALL=1 to download every available update"
    echo "version instead of just the latest (mirrors NPS_DLC_AUTO_ALL)."
}

MY_BINARIES="sed grep curl fzf aria2c"
sha1_choose

check_binaries "${MY_BINARIES}"

TITLE_ID="${1}"

if [ -z "${TITLE_ID}" ]
then
    echo "No title ID found."
    my_usage
    exit 1
fi

check_valid_ps3_id "${TITLE_ID}"
TITLE_ID=$(echo "${TITLE_ID}" | tr '[:lower:]' '[:upper:]')

# make DESTDIR overridable, matching nps_ps3_dlc.sh's convention
if [ -z "${DESTDIR}" ]
then
    DESTDIR="${TITLE_ID}"
fi

UPDATE_XML="$(curl -k -fsS --max-time 30 "https://a0.ww.np.dl.playstation.net/tpl/np/${TITLE_ID}/${TITLE_ID}-ver.xml" 2>/dev/null)"

# Sony's server signals "nothing here" three different ways: an empty
# body, a literal "Not found" string (title never existed on PSN), or an
# <Error><Code>NoSuchKey</Code></Error> body (title exists but has no
# updates) - all three are the same outcome for us.
if [ -z "${UPDATE_XML}" ] || echo "${UPDATE_XML}" | grep -q "Not found" || echo "${UPDATE_XML}" | grep -q "NoSuchKey"
then
    >&2 echo "No updates available for \"${TITLE_ID}\"."
    exit 2
fi

# Each <package version="X" size="N" sha1sum="40hex" url="..."> tag is one
# full, standalone update pkg (PS3 doesn't do delta patches) - extract the
# opening tags (they're not self-closing; each has <paramsfo>/etc. children
# before its closing </package>, so match up to the first ">" only) then
# pull out the four attributes we need per tag.
PACKAGE_TAGS="$(echo "${UPDATE_XML}" | grep -o '<package [^>]*>')"
if [ -z "${PACKAGE_TAGS}" ]
then
    >&2 echo "No updates available for \"${TITLE_ID}\"."
    exit 2
fi

extract_attr() {
    # ${1}=attribute name, reads one <package ...> tag from stdin
    sed -E "s/.*${1}=\"([^\"]*)\".*/\\1/"
}

LIST="$(echo "${PACKAGE_TAGS}" | while IFS= read -r TAG
do
    VERSION="$(echo "${TAG}" | extract_attr version)"
    SIZE="$(echo "${TAG}" | extract_attr size)"
    SHA1SUM="$(echo "${TAG}" | extract_attr sha1sum)"
    URL="$(echo "${TAG}" | extract_attr url)"
    printf "%s\t%s\t%s\t%s\n" "${VERSION}" "${SIZE}" "${SHA1SUM}" "${URL}"
done)"

# Sort newest-first (version strings observed as zero-padded "NN.NN",
# which sorts correctly both lexically and numerically) so "the latest"
# is unambiguous and consistently the first row below.
LIST="$(echo "${LIST}" | sort -t "$(printf '\t')" -k1,1 -r)"
LATEST_VERSION="$(echo "${LIST}" | head -n1 | cut -f1)"

# Let the user pick which update version(s) to download, mirroring
# nps_ps3_dlc.sh's item picker exactly: only the latest version is
# pre-selected by default (Enter alone = "just get me current"), skipped
# entirely (defaults to latest-only, or every version if
# NPS_UPDATE_AUTO_ALL=1) when not running interactively so scripted/
# backgrounded usage never hangs on fzf input.
SELECTED_VERSIONS=""
PICKER_RAN=false
if [ "${NPS_UPDATE_AUTO_ALL}" != "1" ] && [ -t 0 ] && [ -t 1 ]
then
    PICKER_RAN=true

    UPDATE_CANDIDATES="$(echo "${LIST}" | while IFS="$(printf '\t')" read -r VERSION SIZE SHA1SUM URL
    do
        [ -z "${VERSION}" ] && continue
        LABEL="v${VERSION}  $(human_size "${SIZE}")"
        [ "${VERSION}" = "${LATEST_VERSION}" ] && LABEL="${LABEL}  (latest)"
        printf "%s\t%s\n" "${VERSION}" "${LABEL}"
    done)"

    # Same older-fzf "load" bind-event probe already established in
    # nps_ps3_dlc.sh - pre-select only the latest version via a filtered
    # load:select-all, falling back to a plain header hint plus ctrl-a
    # (select all) on fzf builds that don't support "load".
    SELECT_LATEST_BIND="--bind load:select-all"
    FZF_HEADER="enter:confirm selected  tab:toggle  esc:download none"
    if printf 'x\n' | fzf --bind load:select-all --filter '' 2>&1 >/dev/null | grep -q "unsupported key"
    then
        SELECT_LATEST_BIND=""
        FZF_HEADER="ctrl-a:select all  ${FZF_HEADER}  (latest pre-selected below)"
    fi

    SELECTED_VERSIONS="$(echo "${UPDATE_CANDIDATES}" | fzf --multi ${SELECT_LATEST_BIND} --bind ctrl-a:select-all \
        --delimiter="$(printf '\t')" --with-nth=2.. \
        --height=90% --border --prompt="Select update version(s) to download> " \
        --header="${FZF_HEADER}" \
        | cut -f1 | tr '\n' ' ')"

    if [ -z "$(echo "${SELECTED_VERSIONS}" | tr -d '[:space:]')" ]
    then
        exit 2
    fi
elif [ "${NPS_UPDATE_AUTO_ALL}" != "1" ]
then
    # Non-interactive, not asked for everything - just the latest.
    SELECTED_VERSIONS="${LATEST_VERSION}"
fi
# else: NPS_UPDATE_AUTO_ALL=1 with no picker - every row in LIST is used as-is.

if [ -n "${SELECTED_VERSIONS}" ]
then
    FILTERED_LIST="$(echo "${LIST}" | awk -F'\t' -v vers=" ${SELECTED_VERSIONS} " '{ if (index(vers, " " $1 " ") > 0) print }')"
else
    FILTERED_LIST="${LIST}"
fi

MISSING_COUNT=0
EXISTING_COUNT=0
FAILED_COUNT=0

# Bounded parallel fan-out, mirroring nps_ps3_dlc.sh's worker-script +
# xargs -P pattern exactly (including passing only the version string,
# not the full tab-delimited row, through xargs - BSD xargs' "-I"
# collapses embedded tabs to spaces when substituting).
NPS_UPDATE_PARALLEL="${NPS_UPDATE_PARALLEL:-4}"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT
RESULTS_DIR="${WORKDIR}/results"
mkdir -p "${RESULTS_DIR}"

ROWS_FILE="${WORKDIR}/rows.tsv"
echo "${FILTERED_LIST}" > "${ROWS_FILE}"

WORKER_SCRIPT="${WORKDIR}/download-update.sh"
cat > "${WORKER_SCRIPT}" <<EOF
#!/bin/sh
. "${SCRIPT_DIR}/functions.sh"
# xargs -P dispatches this as a separate process, so it doesn't inherit
# the parent script's \$SHA1 tool-selector variable - sha1_choose must
# be called again here or my_sha1_truncated silently hashes nothing.
sha1_choose

VERSION="\${1}"
ROWS_FILE="\${2}"
DESTDIR="\${3}"
RESULTS_DIR="\${4}"
TITLE_ID="\${5}"

ROW="\$(awk -F'\t' -v ver="\${VERSION}" '\$1 == ver { print; exit }' "\${ROWS_FILE}")"

SHA1SUM="\$(echo "\${ROW}" | cut -f3)"
URL="\$(echo "\${ROW}" | cut -f4)"

RESULT_FILE="\${RESULTS_DIR}/\${VERSION}"

FILE_NAME="Update v\${VERSION} [\${TITLE_ID}]"
PKG_PATH="\${DESTDIR}/updates/\${FILE_NAME}.pkg"

if [ -f "\${PKG_PATH}" ]
then
    >&2 echo "File \"\${FILE_NAME}.pkg\" already exists."
    echo "EXISTING" > "\${RESULT_FILE}"
    exit 0
fi

my_download_file "\${URL}" "\${PKG_PATH}"
if [ \${?} -ne 0 ]
then
    >&2 echo "Download of \"\${FILE_NAME}.pkg\" failed."
    rm -f "\${PKG_PATH}"
    echo "FAILED" > "\${RESULT_FILE}"
    exit 0
fi

if [ -n "\${SHA1SUM}" ]
then
    FILE_SHA1="\$(my_sha1_truncated "\${PKG_PATH}")"
    if [ "\${FILE_SHA1}" != "\${SHA1SUM}" ]
    then
        # No interactive confirm-and-keep prompt under parallel dispatch,
        # same rule already established in nps_ps3_dlc.sh's worker.
        >&2 echo "Checksum of \"\${FILE_NAME}.pkg\" does not match Sony's update manifest - failing (no interactive prompt under parallel download)."
        rm -f "\${PKG_PATH}"
        echo "FAILED" > "\${RESULT_FILE}"
        exit 0
    fi
fi

echo "OK" > "\${RESULT_FILE}"
EOF
chmod +x "${WORKER_SCRIPT}"

mkdir -p "${DESTDIR}/updates"

cut -f1 "${ROWS_FILE}" | xargs -I{} -P "${NPS_UPDATE_PARALLEL}" "${WORKER_SCRIPT}" "{}" "${ROWS_FILE}" "${DESTDIR}" "${RESULTS_DIR}" "${TITLE_ID}"

for RESULT_FILE in "${RESULTS_DIR}"/*
do
    [ -e "${RESULT_FILE}" ] || continue
    case "$(cat "${RESULT_FILE}")" in
        EXISTING) EXISTING_COUNT=$((EXISTING_COUNT + 1)) ;;
        FAILED) FAILED_COUNT=$((FAILED_COUNT + 1)) ;;
    esac
done

rm -rf "${WORKDIR}"
trap - EXIT

if [ "${FAILED_COUNT}" -gt 0 ]
then
    exit 6
elif [ "${EXISTING_COUNT}" -gt 0 ] && [ "${FAILED_COUNT}" -eq 0 ]
then
    exit 5
else
    exit 0
fi
