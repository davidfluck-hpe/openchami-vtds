#! /bin/bash
#
# MIT License
#
# (C) Copyright 2026 Hewlett Packard Enterprise Development LP
#
# Permission is hereby granted, free of charge, to any person obtaining a
# copy of this software and associated documentation files (the "Software"),
# to deal in the Software without restriction, including without limitation
# the rights to use, copy, modify, merge, publish, distribute, sublicense,
# and/or sell copies of the Software, and to permit persons to whom the
# Software is furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included
# in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
# THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR
# OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
# ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
# OTHER DEALINGS IN THE SOFTWARE.

# This script runs inside of a Podman container running on a test
# platform. It populates the testing tree by cloning the
# openchami-vtds repository into the container, switching to new
# branch, adding a test_results sub-directory to the branch, filling
# out the templated fields in the 'config.yaml' file and then running
# the test deployment. When the deployment finishes, it collects the
# test results and pushes the results back to the GitHub repository on
# the branch. While the script is running, it commits and pushes
# periodic updates to the branch to allow for progress monitoring.
set -e

# Functions defined here so we can use them anywhere

# Print a message and exit, keeping track of where this function was
# called from
function fail () {
    local message="${1}"; shift || message="no reason given"
    echo "${BASH_SOURCE[1]}:${BASH_LINENO[0]}:[${FUNCNAME[1]}]: ${message}" >&2
    exit 1
}

# Add a new state line to the status file and push the changes back to
# GitHub
function update_status() {
    local status="${1}"; shift || fail "missing status argument"
    local message="${1}"; shift || fail "missing commit message argument"
    echo "$(date): ${status}" >> "${TEST_DIR_PATH}/status"
    git commit -a -m "${message}"
    git push --set-upstream origin 
}

# Runs a command in the background, monitoring its progress, updating
# GitHub and handling timeouts as needed.
function run_monitored() {
    # Arguments
    local interval="${1}"; shift || fail "no update interval specified"
    local timeout="${1}"; shift || fail "no timeout value specified"
    local run_state="${1}"; shift || fail "no running state specified"
    local final_state="${1}"; shift || fail "no final state specified"
    local fail_state="${1}"; shift || fail "no failure state specified"
    local to_state="${1}"; shift || fail "no timeout state specified"
    local cmd="${1}"; shift || fail "no command specified"

    # Run the commands with its arguments (the rest of the command line)
    # in the background.
    "${cmd}" "$@" >> "${TEST_DIR_PATH}"/deploy_output.txt 2>&1 &
    local task_pid="${!}"

    # Monitor the command and update periodically. Also fail if the
    # command times out while still running.
    local seconds=0
    local task_timer=0
    local updates=1
    update_status "${run_state}" \
                  "Test run ${TEST_RUN_NAME} ${run_state} [${updates}]"
    while kill -0 "${task_pid}" 2> /dev/null; do
        task_timer="$(( "${task_timer}" + 1 ))"
        if [ "${task_timer}" -gt "${timeout}" ]; then
            # The deployment ran out of time. Note the timeout in the status
            # log and break out of this loop.
            update_status \
                "${to_state}" \
                "Test run ${TEST_RUN_NAME} ${to_state} ${task_timer} sec"
            kill -TERM "${task_pid}"
            break
        fi
        if [ "${seconds}" -ge "${interval}" ]; then
            updates="$(( "${updates}" + 1 ))"
            update_status "${run_state}" \
                          "Test run ${TEST_RUN_NAME} ${run_state} [${updates}]"
            seconds=0
        fi
        # No timeout, so keep trying..
        seconds="$(( "${seconds}" + 1 ))"
        sleep 1
    done
    # Get the exit status from the deploy
    if ! wait "${task_pid}"; then
        update_status "${fail_state}" \
                      "Test run ${TEST_RUN_NAME} ${fail_state}"
    else
        update_status "${final_state}" \
                      "Test run ${TEST_RUN_NAME} ${final_state}"
    fi
}

# Generate a safe string to use in naming a GCP project using the test
# run name as input.
function make_cluster_name() {
    local test_run_name="${1}"; shift || fail "no test run name provided"

    echo "${test_run_name}" | md5sum | cut -c 1-10
}

# Some variables used to set up the test enviromnent and configure the
# tests.
: "${TEST_TIMESTAMP:="$(TZ=UTC date +%y%m%d%H%M%S)"}"
: "${TEST_REPO_URL:="git@github.com:Cray-HPE/openchami-vtds.git"}"
: "${TEST_REPO_TREE:="$(pwd)/openchami-vtds"}"
: "${OPENCHAMI_VERSION:="main"}"
: "${TEST_RUN_NAME:="${OPENCHAMI_VERSION}-${TEST_TIMESTAMP}"}"
: "${TEST_CLUSTER_NAME:="$(make_cluster_name "${TEST_RUN_NAME}")"}"
: "${TEST_UPDATE_INTERVAL:=600}"
: "${TEST_DEPLOY_TIMEOUT:=7200}"
: "${TEST_REMOVE_TIMEOUT:=1800}"
: "${VTDS_CONFIG_TEMPLATE:="config.yaml"}"
: "${GITHUB_KEY_SECRET_NAME:="github-deploy-key"}"
: "${GITHUB_EMAIL:="77127214+erl-hpe@users.noreply.github.com"}"
: "${GITHUB_USER:="OpenCHAMI Test Runner"}"
TEST_DIR_PATH="${TEST_REPO_TREE}"/test_results/"${TEST_RUN_NAME}"
TEST_INFRASTRUCTURE_PATH="${TEST_REPO_TREE}"/infrastructure
TEST_LOG_PATH="${TEST_DIR_PATH}"/vtds-build/cluster/logs
TEST_RUN_BRANCH="test-run/${TEST_RUN_NAME}"

# Set up keys for access to the GitHub test repository
mkdir -p /root/.ssh
touch /root/.ssh/id_rsa
chmod 600 /root/.ssh/id_rsa
gcloud secrets versions access latest \
       --secret="${GITHUB_KEY_SECRET_NAME}" > /root/.ssh/id_rsa

# Make sure we "know" the host key for GitHub
ssh-keyscan github.com >> /root/.ssh/known_hosts

# Set up the test environment
git clone "${TEST_REPO_URL}" "${TEST_REPO_TREE}"
cd "${TEST_REPO_TREE}"
git config --global user.email "${GITHUB_EMAIL}"
git config --global user.name "${GITHUB_USER}"
git checkout -b "${TEST_RUN_BRANCH}"
git push --set-upstream origin "${TEST_RUN_BRANCH}"
mkdir "${TEST_DIR_PATH}"
cp "${TEST_REPO_TREE}/infrastructure/${VTDS_CONFIG_TEMPLATE}" \
   "${TEST_DIR_PATH}"/config.yaml
cd "${TEST_DIR_PATH}"
touch "${TEST_DIR_PATH}/status"
touch "${TEST_DIR_PATH}/deploy_output.txt"
git add status
git add deploy_output.txt
git add config.yaml
update_status "PENDING" "Test run ${TEST_RUN_NAME} PENDING"

# Configure the deployment
sed -i \
    -e "s/%%TEST_CLUSTER_NAME%%/${TEST_CLUSTER_NAME}/g" \
    -e "s/%%OPENCHAMI_VERSION%%/${OPENCHAMI_VERSION}/g" \
    "${TEST_DIR_PATH}"/config.yaml
git commit -a -m "Test run ${TEST_RUN_NAME} configured"

# Capture the status and start capturing the deployment logs and data
# in case something fails badly.
vtds show_config | \
    sed -e 's/redfish_password: .*$/redfish_password: null # Removed/' > \
    full_config.yaml
git add vtds-build
git add full_config.yaml

# Start the deployment in the background and start waiting for it
run_monitored \
    "${TEST_UPDATE_INTERVAL}" \
    "${TEST_DEPLOY_TIMEOUT}" \
    "DEPLOYING" \
    "DEPLOYED" \
    "DEPLOY_FAILED" \
    "DEPLOY_TIMED_OUT" \
    vtds deploy

# Collect test results if any...
if ls "${TEST_LOG_PATH}"/TEST-CASE-*-out.txt > /dev/null 2>&1; then
    ls "${TEST_LOG_PATH}"/TEST-CASE-*-out.txt | while read log; do
        # Put a delimiter into the raw test results so that we can
        # find the starting test boundary.
        rel_path="$(echo "${log}" | sed -e "s:${TEST_DIR_PATH}/::")"
        echo "++++++++ ${rel_path} ++++++++" >> \
             "${TEST_DIR_PATH}/raw_test_results.txt"
        # Capture the test results. Strip away the 'Last login' line at
        # the top. Also make sure any instance of 8 plus signs aligned
        # with the first column is in the test results is indented one
        # space so that the delimiting above is reliable.
        sed -e "1{/Last login[:]/d}" -e "s/^+++++++/ ++++++++/"< "${log}" >> \
            "${TEST_DIR_PATH}/raw_test_results.txt"
    done
    git add "${TEST_DIR_PATH}/raw_test_results.txt"
fi
git add "${TEST_DIR_PATH}/vtds-build"

# Remove the vTDS cluster
run_monitored \
    "${TEST_UPDATE_INTERVAL}" \
    "${TEST_REMOVE_TIMEOUT}" \
    "REMOVING" \
    "REMOVED" \
    "REMOVE_FAILED" \
    "REMOVE_TIMED_OUT" \
    vtds remove

# All done, update the status and get out clean
update_status COMPLETE "Test run ${TEST_RUN_NAME} COMPLETE"

# Clean up
rm -rf "${TEST_REPO_TREE}"
exit 0
