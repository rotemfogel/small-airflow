#!/usr/bin/env bash

# Runs airflow-dags tests.

# Set Nose defaults if no arguments are passed from CLI.
NOSE_ARGS=$@
if [ -z "$NOSE_ARGS" ]; then
  NOSE_ARGS=" \
    --with-coverage \
    --with-doctest \
    --cover-erase \
    --cover-package=dags \
    --cover-html-dir=build/coverage \
    --cover-html \
    --with-xunit \
    --xunit-file=build/test_output.xml \
    -s \
    -v \
    --logging-level=INFO"
fi

# Export for the DAGs import test.
if [ -f init_env ];
then
  . init_env
fi

# Create a build directory to store test output.
mkdir -p build

# check for previously created DB
python <<EOF
from airflow import settings
from airflow.models import Connection
session = settings.Session()
conn_exists = session.query(Connection).filter_by(conn_id='sadw_eon').first()
assert(conn_exists)
EOF

if [ $? -eq 0 ]; then
  # all is well, no need to recreate the DB
  echo 'Reusing previous airflow database'
else
  # create variables from yaml
  python <<EOF
import yaml, json
with open("tests/variables.yaml") as yaml_file:
    variables = yaml.safe_load(yaml_file)
with open("tests/variables.json", "w") as json_file:
    json.dump(variables, json_file)
EOF

  # set up DB
  rm -rf tests/unittests.db
  airflow resetdb -y
  airflow variables import tests/variables.json
  airflow connections add --conn-host 127.0.0.1 --conn-login ro --conn-port 5433 --conn-schema sadw_eon --conn-type vertica sadw_eon

  rm tests/variables.json
fi

# Run Flake to make sure things are stylish.
flake8 --max-line-length 132 --max-complexity 12 dags

# Run tests.
nosetests ${NOSE_ARGS}

if [ $? -ne 0 ]; then
  echo 'nose_tests test Failed, exiting'
  exit 2
fi
