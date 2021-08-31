#!/bin/bash

uniq_tag="$$@$(date +%s)"

BASE_DIR="$(realpath ~)"
TARGET_DIR="${BASE_DIR}/src/tar/data-science-airflow"
DATED_DIR="${TARGET_DIR}-${uniq_tag}"
OLD_DIR=$(realpath "${TARGET_DIR}")
TARGET_VENV="${BASE_DIR}/venv/airflow"
DATED_VENV="${TARGET_VENV}-${uniq_tag}"
OLD_VENV=$(realpath "${TARGET_VENV}")

# $1 = error message
function die() {
  curr_venv=$(realpath "${TARGET_VENV}")
  if [ "${DATED_VENV}" = "${curr_venv}" ]; then
    ln -nfs "${OLD_VENV}" "${TARGET_VENV}"
  fi
  rm -rf "${DATED_DIR}" "${DATED_VENV}"
  text="FAILURE: $0: $1"
  echo "$text" >&2
  exit 120
}

echo Downloading latest tarball...
rm -rf "${DATED_DIR}"
mkdir -p "${DATED_DIR}"
cd "${DATED_DIR}" || die "${DATED_DIR} does not exist $?"
tar xf "${BASE_DIR}/src/git/data-science-airflow/release.tar.xz" || die "couldn't extract tarball $?"

rm -rf "${DATED_VENV}"
mkdir -p "${DATED_VENV}"
ln -nfs "${DATED_VENV}" "${TARGET_VENV}"
virtualenv -p python3.7 "${TARGET_VENV}" || echo "couldn't set up virtualenv $?"
./wheelfreeze/install "${TARGET_VENV}" || die "couldn't install packages $?"

# Use our config, with new dags&plugins, don't create "testing" config files
(
  export AIRFLOW_HOME="${HOME}/airflow"
  export AIRFLOW__CORE__DAGS_FOLDER="${DATED_DIR}/code/dags"
  export AIRFLOW__CORE__PLUGINS_FOLDER="${DATED_DIR}/code/plugins"
  "${TARGET_VENV}"/bin/airflow list_dags
) || die "list_dags failed to run $?"

ln -nfs "${DATED_DIR}/code" "${TARGET_DIR}"

# Cleaning up deploys and envs older than 6 latest
for dir in $(ls -ctd ${BASE_DIR}/venv/*airflow* | tail -n +6 ); do rm -rf $dir; done
for dir in $(ls -ctd ${BASE_DIR}/src/tar/*airflow* | tail -n +6 ); do rm -rf $dir; done

echo Done!
