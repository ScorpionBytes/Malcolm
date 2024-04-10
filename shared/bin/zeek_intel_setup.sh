#!/usr/bin/env bash

# Copyright (c) 2024 Battelle Energy Alliance, LLC.  All rights reserved.

# set up intel files prior to running zeek
#   - https://idaholab.github.io/Malcolm/docs/zeek-intel.html#ZeekIntel
#   - https://github.com/idaholab/Malcolm/issues/20
# used as the Zeek Dockerfile's entrypoint as well

set -uo pipefail
shopt -s nocasematch
ENCODING="utf-8"

SCRIPT_FILESPEC="$(realpath -e "${BASH_SOURCE[0]}")"
SCRIPT_FILESPEC_ESCAPED="$(printf '%s\n' "${SCRIPT_FILESPEC}" | sed -e 's/[\/&]/\\&/g')"
ZEEK_DIR=${ZEEK_DIR:-"/opt/zeek"}
ZEEK_INTEL_ITEM_EXPIRATION=${ZEEK_INTEL_ITEM_EXPIRATION:-"-1min"}
ZEEK_INTEL_FEED_SINCE=${ZEEK_INTEL_FEED_SINCE:-""}
ZEEK_INTEL_FEED_SSL_CERTIFICATE_VERIFICATION=${ZEEK_INTEL_FEED_SSL_CERTIFICATE_VERIFICATION:-false}
ZEEK_INTEL_REFRESH_THREADS=${ZEEK_INTEL_REFRESH_THREADS:-"2"}
INTEL_DIR=${INTEL_DIR:-"${ZEEK_DIR}/share/zeek/site/intel"}
INTEL_PRESEED_DIR=${INTEL_PRESEED_DIR:-"${ZEEK_DIR}/share/zeek/site/intel-preseed"}
THREAT_FEED_TO_ZEEK_SCRIPT=${THREAT_FEED_TO_ZEEK_SCRIPT:-"${ZEEK_DIR}/bin/zeek_intel_from_threat_feed.py"}
LOCK_DIR="${INTEL_DIR}/lock"

# make sure only one instance of the intel update runs at a time
function finish {
    rmdir -- "$LOCK_DIR" || echo "Failed to remove lock directory '$LOCK_DIR'" >&2
}

mkdir -p -- "$(dirname "$LOCK_DIR")"
if mkdir -- "$LOCK_DIR" 2>/dev/null; then
    trap finish EXIT

    # if we have a directory to seed the intel config for the first time, start from a blank slate with just its contents
    if [[ -d "${INTEL_DIR}" ]] && [[ -d "${INTEL_PRESEED_DIR}" ]]; then

        EXCLUDES=()
        EXCLUDES+=( --exclude='..*' )
        EXCLUDES+=( --exclude='.dockerignore' )
        EXCLUDES+=( --exclude='.gitignore' )
        while read MAP_DIR; do
            EXCLUDES+=( --exclude="${MAP_DIR}/" )
        done < <(echo "${CONFIG_MAP_DIR:-configmap;secretmap}" | tr ';' '\n')

        rsync --recursive --delete --delete-excluded "${EXCLUDES[@]}" "${INTEL_PRESEED_DIR}"/ "${INTEL_DIR}"/
        mkdir -p "${INTEL_DIR}"/MISP "${INTEL_DIR}"/STIX || true
    fi

    # create directive to @load every subdirectory in /opt/zeek/share/zeek/site/intel
    if [[ -d "${INTEL_DIR}" ]] && (( $(find "${INTEL_DIR}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l) > 0 )); then
        pushd "${INTEL_DIR}" >/dev/null 2>&1

        cat > ./__load__.zeek.new << EOF
# WARNING: This file is automatically generated.
# Do not make direct modifications here.
@load policy/integration/collective-intel
@load policy/frameworks/intel/seen
@load policy/frameworks/intel/do_notice
@load policy/frameworks/intel/do_expire

redef Intel::item_expiration = ${ZEEK_INTEL_ITEM_EXPIRATION};

EOF
        LOOSE_INTEL_FILES=()
        THREAT_JSON_FILES=()

        # process subdirectories under INTEL_DIR
        for DIR in $(find . -mindepth 1 -maxdepth 1 -type d 2>/dev/null | grep -v -P "$(echo "${CONFIG_MAP_DIR:-configmap;secretmap}" | sed 's/\(.*\)/^.\/(\1)$/' | tr ';' '|')"); do

            if [[ "${DIR}" == "./STIX" ]]; then
                # this directory contains STIX JSON files we'll need to convert to zeek intel files then load
                while IFS= read -r line; do
                    THREAT_JSON_FILES+=( "$line" )
                done < <( find "${INTEL_DIR}/${DIR}" -type f ! -name ".*" 2>/dev/null )

            elif [[ "${DIR}" == "./MISP" ]]; then
                # this directory contains MISP JSON files we'll need to convert to zeek intel files then load
                while IFS= read -r line; do
                    THREAT_JSON_FILES+=( "$line" )
                done < <( find "${INTEL_DIR}/${DIR}" -type f ! -name ".*" ! -name "manifest.json" ! -name "hashes.csv" 2>/dev/null )

            elif [[ -f "${DIR}"/__load__.zeek ]]; then
                # this intel feed has its own load directive and should take care of itself
                echo "@load ${DIR}" >> ./__load__.zeek.new
            else
                # this directory contains "loose" intel files we'll need to load explicitly
                while IFS= read -r line; do
                    LOOSE_INTEL_FILES+=( "$line" )
                done < <( find "${INTEL_DIR}/${DIR}" -type f ! -name ".*" 2>/dev/null )
            fi
        done

        # process STIX and MISP inputs by converting them to Zeek intel format
        if ( (( ${#THREAT_JSON_FILES[@]} )) || [[ -r ./STIX/.stix_input.txt ]] || [[ -r ./MISP/.misp_input.txt ]] ) && [[ -x "${THREAT_FEED_TO_ZEEK_SCRIPT}" ]]; then
            "${THREAT_FEED_TO_ZEEK_SCRIPT}" \
                --ssl-verify ${ZEEK_INTEL_FEED_SSL_CERTIFICATE_VERIFICATION} \
                --since "${ZEEK_INTEL_FEED_SINCE}" \
                --threads ${ZEEK_INTEL_REFRESH_THREADS} \
                --output ./.threat_autogen.zeek.new \
                --input "${THREAT_JSON_FILES[@]}" \
                --input-file ./STIX/.stix_input.txt ./MISP/.misp_input.txt
            mv --backup=simple --suffix=.old ./.threat_autogen.zeek.new ./.threat_autogen.zeek
            rm -f ./.threat_autogen.zeek.old
            LOOSE_INTEL_FILES+=( "${INTEL_DIR}"/.threat_autogen.zeek )
        else
            rm -f ./.threat_autogen.zeek*
        fi

        # explicitly load all of the "loose" intel files in other subdirectories that didn't __load__ themselves
        if (( ${#LOOSE_INTEL_FILES[@]} )); then
            echo >> ./__load__.zeek.new
            echo 'redef Intel::read_files += {' >> ./__load__.zeek.new
            for INTEL_FILE in "${LOOSE_INTEL_FILES[@]}"; do
                echo "  \"${INTEL_FILE}\"," >> ./__load__.zeek.new
            done
            echo '};' >> ./__load__.zeek.new
        fi

        mv --backup=simple --suffix=.old ./__load__.zeek.new ./__load__.zeek
        rm -f ./__load__.zeek.old

        popd >/dev/null 2>&1
    fi

    finish
    trap - EXIT
fi # singleton lock check

# if supercronic is being used to periodically refresh the intel sources,
# write a cron entry to $SUPERCRONIC_CRONTAB using the interval specified in
# $ZEEK_INTEL_REFRESH_CRON_EXPRESSION (e.g., 15 1 * * *) to execute this script
set +u
if [[ -n "${SUPERCRONIC_CRONTAB}" ]] && [[ -f "${SUPERCRONIC_CRONTAB}" ]]; then
    touch "${SUPERCRONIC_CRONTAB}"
    sed -i -e "/${SCRIPT_FILESPEC_ESCAPED}/d" "${SUPERCRONIC_CRONTAB}"
    if [[ -n "${ZEEK_INTEL_REFRESH_CRON_EXPRESSION}" ]]; then
        echo "${ZEEK_INTEL_REFRESH_CRON_EXPRESSION} ${SCRIPT_FILESPEC} true" >> "${SUPERCRONIC_CRONTAB}"
    fi
    # reload supercronic if it's running
    killall -s USR2 supercronic >/dev/null 2>&1 || true
fi

# start supervisor to spawn the other process(es) or whatever the default command is
exec "$@"
