#!/bin/bash

set -eu

function usage {
  echo "Usage: $0 [OPTION]..."
  echo "Run python-keystoneclient test suite"
  echo ""
  echo "  -V, --virtual-env        Always use virtualenv.  Install automatically if not present"
  echo "  -N, --no-virtual-env     Don't use virtualenv.  Run tests in local environment"
  echo "  -s, --no-site-packages   Isolate the virtualenv from the global Python environment"
  echo "  -x, --stop               Stop running tests after the first error or failure."
  echo "  -f, --force              Force a clean re-build of the virtual environment. Useful when dependencies have been added."
  echo "  -u, --update             Update the virtual environment with any newer package versions"
  echo "  -p, --pep8               Just run pep8"
  echo "  -P, --no-pep8            Don't run pep8"
  echo "  -c, --coverage           Generate coverage report"
  echo "  -d, --debug              Run tests with testtools instead of testr. This allows you to use the debugger."
  echo "  -h, --help               Print this usage message"
  echo "  --hide-elapsed           Don't print the elapsed time for each test along with slow test list"
  echo ""
  echo "Note: with no options specified, the script will try to run the tests in a virtual environment,"
  echo "      If no virtualenv is found, the script will ask if you would like to create one.  If you "
  echo "      prefer to run tests NOT in a virtual environment, simply pass the -N option."
  exit
}

function process_option {
  case "$1" in
    -h|--help) usage;;
    -V|--virtual-env) always_venv=1; never_venv=0;;
    -N|--no-virtual-env) always_venv=0; never_venv=1;;
    -s|--no-site-packages) no_site_packages=1;;
    -f|--force) force=1;;
    -u|--update) update=1;;
    -p|--pep8) just_pep8=1;;
    -P|--no-pep8) no_pep8=1;;
    -c|--coverage) coverage=1;;
    -d|--debug) debug=1;;
    -*) testropts="$testropts $1";;
    *) testrargs="$testrargs $1"
  esac
}

venv=.venv
with_venv=tools/with_venv.sh
always_venv=0
never_venv=0
force=0
no_site_packages=0
installvenvopts=
testrargs=
testropts=
wrapper=""
just_pep8=0
no_pep8=0
coverage=0
debug=0
update=0

LANG=en_US.UTF-8
LANGUAGE=en_US:en
LC_ALL=C
OS_STDOUT_NOCAPTURE=False
OS_STDERR_NOCAPTURE=False

for arg in "$@"; do
  process_option $arg
done

if [ $no_site_packages -eq 1 ]; then
  installvenvopts="--no-site-packages"
fi

function init_testr {
  if [ ! -d .testrepository ]; then
    ${wrapper} testr init
  fi
}

function run_tests {
  # Cleanup *.pyc
  ${wrapper} find . -type f -name "*.pyc" -delete

  if [ $debug -eq 1 ]; then
    if [ "$testropts" = "" ] && [ "$testrargs" = "" ]; then
      # Default to running all tests if specific test is not
      # provided.
      testrargs="discover ./tests"
    fi
    ${wrapper} python -m testtools.run $testropts $testrargs

    # Short circuit because all of the testr and coverage stuff
    # below does not make sense when running testtools.run for
    # debugging purposes.
    return $?
  fi

  if [ $coverage -eq 1 ]; then
    TESTRTESTS="$TESTRTESTS --coverage"
  else
    TESTRTESTS="$TESTRTESTS"
  fi

  # Just run the test suites in current environment
  set +e
  testrargs=`echo "$testrargs" | sed -e's/^\s*\(.*\)\s*$/\1/'`
  TESTRTESTS="$TESTRTESTS --testr-args='$testropts $testrargs'"
  echo "Running \`${wrapper} $TESTRTESTS\`"
  bash -c "${wrapper} $TESTRTESTS"
  RESULT=$?
  set -e

  copy_subunit_log

  if [ $coverage -eq 1 ]; then
    echo "Generating coverage report in covhtml/"
    # Don't compute coverage for common code, which is tested elsewhere
    ${wrapper} coverage combine
    ${wrapper} coverage html --include='keystoneclient/*' --omit='keystoneclient/openstack/common/*' -d covhtml -i
  fi

  return $RESULT
}

function copy_subunit_log {
  LOGNAME=`cat .testrepository/next-stream`
  LOGNAME=$(($LOGNAME - 1))
  LOGNAME=".testrepository/${LOGNAME}"
  cp $LOGNAME subunit.log
}

function run_pep8 {
  echo "Running pep8 ..."
  srcfiles="keystoneclient tests"
  # Just run PEP8 in current environment
  #
  # NOTE(heckj): E125, E126 are being ignored matching other openstack projects
  # for pep 1.3.3 due to relatively arbitrary line indentation rulings
  ${wrapper} pep8 --repeat --show-pep8 --show-source \
    --ignore=E125,E126 --exclude=.venv,.tox,dist,doc,build \
    ${srcfiles}
}

TESTRTESTS="python setup.py testr"

if [ $never_venv -eq 0 ]
then
  # Remove the virtual environment if --force used
  if [ $force -eq 1 ]; then
    echo "Cleaning virtualenv..."
    rm -rf ${venv}
  fi
  if [ $update -eq 1 ]; then
      echo "Updating virtualenv..."
      python tools/install_venv.py
  fi
  if [ -e ${venv} ]; then
    wrapper="${with_venv}"
  else
    if [ $always_venv -eq 1 ]; then
      # Automatically install the virtualenv
      python tools/install_venv.py $installvenvopts
      wrapper="${with_venv}"
    else
      echo -e "No virtual environment found...create one? (Y/n) \c"
      read use_ve
      if [ "x$use_ve" = "xY" -o "x$use_ve" = "x" -o "x$use_ve" = "xy" ]; then
        # Install the virtualenv and run the test suite in it
        python tools/install_venv.py $installvenvopts
        wrapper=${with_venv}
      fi
    fi
  fi
fi

# Delete old coverage data from previous runs
if [ $coverage -eq 1 ]; then
    ${wrapper} coverage erase
fi

if [ $just_pep8 -eq 1 ]; then
    run_pep8
    exit
fi

init_testr
run_tests

# NOTE(sirp): we only want to run pep8 when we're running the full-test suite,
# not when we're running tests individually. To handle this, we need to
# distinguish between options (testropts), which begin with a '-', and
# arguments (testrargs).
if [ -z "$testrargs" ]; then
  if [ $no_pep8 -eq 0 ]; then
    run_pep8
  fi
fi
