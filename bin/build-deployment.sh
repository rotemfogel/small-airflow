#!/bin/bash
# cleanup
\rm -rf release.* requirements.txt wheelfreeze
# build
git archive --output=release.tar --prefix=code/ HEAD
pipenv --python '3.7' lock -r > requirements.txt
virtual_env=$(pipenv --venv)
. "$virtual_env"/bin/activate
pip install --upgrade pip setuptools
pip wheel --wheel-dir=wheelfreeze/wheels -r requirements.txt
cat > wheelfreeze/install <<'INSTALL'
#!/bin/sh
set -e
virtual_env=$1
virtual_env=$(realpath -s "$virtual_env" ||:)
if ! [ -f "$virtual_env"/bin/activate ]; then
    echo >&2 "Usage: $0 path/to/venv"
    exit 1
fi
. "$virtual_env"/bin/activate
pip install --upgrade pip
pip install --upgrade setuptools
wheelfreeze_base="$(realpath -s "$(dirname "$0")")"
pip install --no-deps "$wheelfreeze_base"/wheels/*.whl
INSTALL
chmod +x wheelfreeze/install
# a fix for long file names - assuming all ascii characters
# tar supports file names up to 255 bytes
# e.g. MarkupSafe wheel file name is more than 255 bytes
for filename in wheelfreeze/wheels/*;
do
  if [ "${#filename}" -gt 120 ];
  then
     target_name="${filename:0:115}"
     mv $filename ${target_name}.whl;
  fi
done
tar --append -f release.tar wheelfreeze/
xz release.tar
