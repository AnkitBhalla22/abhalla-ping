#!/bin/bash

########################################################################################################################
#
# Note: This script must be executed within its git checkout tree after switching to the desired branch.
#
# This script may be used to generate the initial Kubernetes configurations to push into the cluster-state repository
# for a particular tenant. This repo is referred to as the cluster state repo because the EKS clusters are always
# (within a few minutes) reflective of the code in this repo. This repo is the only interface for updates to the
# clusters. In other words, kubectl commands that alter the state of the cluster are verboten outside of this repo.
#
# The intended audience of this repo is primarily the Ping Professional Services and Support team, with limited access
# granted to Customer administrators. These users may further tweak the cluster state per the tenant's requirements.
# They are expected to have an understanding of Kubernetes manifest files and kustomize, a client-side tool used to make
# further customizations to the initial state generated by this script.
#
# The script generates Kubernetes manifest files for 4 different environments - dev, test, stage and prod. The
# manifest files for these environments contain deployments of both the Ping Cloud stack and the supporting tools
# necessary to provide an end-to-end solution.
#
# For example, the script produces a directory structure as shown below (Directories greater than a depth of 3 and
# files within the directories are omitted for brevity):
#
# ├── cluster-state
# │   └── k8s-configs
# │       ├── dev
# │       ├── prod
# │       ├── stage
# │       └── test
# │   └── profiles
# └── fluxcd
#    ├── dev
#    ├── prod
#    ├── stage
#    └── test
#
# Deploying the manifests under the fluxcd directory for a specific environment will bootstrap the cluster with a
# Continuous Delivery tool called flux. Once flux is deployed to the cluster, it will deploy the rest of the ping stack
# and supporting tools for that environment. More details on flux may be found here: https://docs.fluxcd.io/
#
# ------------
# Requirements
# ------------
# The script requires the following tools to be installed:
#   - openssl
#   - ssh-keygen
#   - ssh-keyscan
#   - base64
#   - envsubst
#   - git
#
# ------------------
# Usage instructions
# ------------------
# The script does not take any parameters, but rather acts on environment variables. The environment variables will
# be substituted into the variables in the yaml template files. The following mandatory environment variables must be
# present before running this script:
#
# ----------------------------------------------------------------------------------------------------------------------
# Variable                    | Purpose
# ----------------------------------------------------------------------------------------------------------------------
# PING_IDENTITY_DEVOPS_USER   | A user with license to run Ping Software
# PING_IDENTITY_DEVOPS_KEY    | The key to the above user
#
# In addition, the following environment variables, if present, will be used for the following purposes:
#
# ----------------------------------------------------------------------------------------------------------------------
# Variable               | Purpose                                            | Default (if not present)
# ----------------------------------------------------------------------------------------------------------------------
# TENANT_NAME            | The name of the tenant, e.g. k8s-icecream. If      | ci-cd
#                        | provided, this value will be used for the cluster  |
#                        | name and must have the correct case (e.g. ci-cd    |
#                        | vs. CI-CD). If not provided, this variable is      |
#                        | not used, and the cluster name defaults to the CDE |
#                        | name.                                              |
#                        |                                                    |
# TENANT_DOMAIN          | The tenant's domain suffix that's common to all    | ci-cd.ping-oasis.com
#                        | CDEs e.g. k8s-icecream.com. The tenant domain in   |
#                        | each CDE is assumed to have the CDE name as the    |
#                        | prefix, followed by a hyphen. For example, for the |
#                        | above suffix, the tenant domain for stage is       |
#                        | assumed to be stage-k8s-icecream.com and a hosted  |
#                        | zone assumed to exist on Route53 for that domain.  |
#                        |                                                    |
# REGION                 | The region where the tenant environment is         | us-west-2
#                        | deployed. For PCPT, this is a required parameter   |
#                        | to Container Insights, an AWS-specific logging     |
#                        | and monitoring solution.                           |
#                        |                                                    |
# REGION_NICK_NAME       | An optional nick name for the region. For example, | Same as REGION.
#                        | this variable may be set to a unique name in       |
#                        | multi-cluster deployments which live in the same   |
#                        | region. The nick name will be used as the name of  |
#                        | the region-specific code directory in the cluster  |
#                        | state repo.                                        |
#                        |                                                    |
# IS_MULTI_CLUSTER       | Flag indicating whether or not this is a           | false
#                        | multi-cluster deployment.                          |
#                        |                                                    |
# PRIMARY_TENANT_DOMAIN  | In multi-cluster environments, the primary domain. | Same as TENANT_DOMAIN.
#                        | Only used if IS_MULTI_CLUSTER is true.             |
#                        |                                                    |
# PRIMARY_REGION         | In multi-cluster environments, the primary region. | Same as REGION.
#                        | Only used if IS_MULTI_CLUSTER is true.             |
#                        |                                                    |
# CLUSTER_BUCKET_NAME    | The name of the S3 bucket where clustering         | No default. Required if IS_MULTI_CLUSTER
#                        | information is maintained. Only used if            | is true.
#                        | IS_MULTI_CLUSTER is true.                          |
#                        |                                                    |
# SIZE                   | Size of the environment, which pertains to the     | small
#                        | number of user identities. Legal values are        |
#                        | small, medium or large.                            |
#                        |                                                    |
# CLUSTER_STATE_REPO_URL | The URL of the cluster-state repo.                 | https://github.com/pingidentity/ping-cloud-base
#                        |                                                    |
# ARTIFACT_REPO_URL      | The URL for plugins (e.g. PF kits, PD extensions). | The string "unused".
#                        | If not provided, the Ping stack will be            |
#                        | provisioned without plugins. This URL must always  |
#                        | have an s3 scheme, e.g.                            |
#                        | s3://customer-repo-bucket-name.                    |
#                        |                                                    |
# PING_ARTIFACT_REPO_URL | This environment variable can be used to overwrite | https://ping-artifacts.s3-us-west-2.amazonaws.com
#                        | the default endpoint for public plugins. This URL  |
#                        | must use an https scheme as shown by the default   |
#                        | value.                                             |
#                        |                                                    |
# LOG_ARCHIVE_URL        | The URL of the log archives. If provided, logs are | The string "unused".
#                        | periodically captured and sent to this URL. For    |
#                        | AWS S3 buckets, it must be an S3 URL, e.g.         |
#                        | s3://logs.                                         |
#                        |                                                    |
# BACKUP_URL             | The URL of the backup location. If provided, data  | The string "unused".
#                        | backups are periodically captured and sent to this |
#                        | URL. For AWS S3 buckets, it must be an S3 URL,     |
#                        | e.g. s3://backups.                                 |
#                        |                                                    |
# K8S_GIT_URL            | The Git URL of the Kubernetes base manifest files. | https://github.com/pingidentity/ping-cloud-base
#                        |                                                    |
# K8S_GIT_BRANCH         | The Git branch within the above Git URL.           | The git branch where this script
#                        |                                                    | exists, i.e. CI_COMMIT_REF_NAME
#                        |                                                    |
# REGISTRY_NAME          | The registry hostname for the Docker images used   | docker.io
#                        | by the Ping stack. This can be Docker hub, ECR     |
#                        | (1111111111.dkr.ecr.us-east-2.amazonaws.com), etc. |
#                        |                                                    |
# SSH_ID_PUB_FILE        | The file containing the public-key (in PEM format) | No default
#                        | used by FluxCD and the Ping containers to access   |
#                        | the cluster state and config repos, respectively.  |
#                        | If not provided, a new key-pair will be generated  |
#                        | by the script. If provided, the SSH_ID_KEY_FILE    |
#                        | must also be provided and correspond to this       |
#                        | public key.                                        |
#                        |                                                    |
# SSH_ID_KEY_FILE        | The file containing the private-key (in PEM        | No default
#                        | format) used by FluxCD and the Ping containers to  |
#                        | access the cluster state and config repos,         |
#                        | respectively. If not provided, a new key-pair      |
#                        | will be generated by the script. If provided, the  |
#                        | SSH_ID_PUB_FILE must also be provided and          |
#                        | correspond to this private key.                    |
#                        |                                                    |
# TARGET_DIR             | The directory where the manifest files will be     | /tmp/sandbox
#                        | generated. If the target directory exists, it will |
#                        | be deleted.                                        |
#                        |
# IS_BELUGA_ENV          | An optional flag that may be provided to indicate  | false. Only intended for Beluga
#                        | that the cluster state is being generated for      | developers.
#                        | testing during Beluga development. If set to true, |
#                        | the cluster name is assumed to be the tenant name  |
#                        | and the tenant domain assumed to be the same       |
#                        | across all 4 CDEs. On the other hand, in PCPT, the |
#                        | cluster name for the CDEs are hardcoded to dev,    |
#                        | test, stage and prod. The domain names for the     |
#                        | CDEs are derived from the TENANT_DOMAIN variable   |
#                        | as documented above. This flag exists because the  |
#                        | Beluga developers only have access to one domain   |
#                        | and hosted zone in their Ping IAM account role.    |
########################################################################################################################

#### SCRIPT START ####

# Ensure that this script works from any working directory.
SCRIPT_HOME=$(cd $(dirname ${0}) 2>/dev/null; pwd)
pushd "${SCRIPT_HOME}" >/dev/null 2>&1

# Source some utility methods.
. ../utils.sh

########################################################################################################################
# Substitute variables in all template files in the provided directory.
#
# Arguments
#   ${1} -> The directory that contains the template files.
########################################################################################################################

# The list of variables in the template files that will be substituted by default.
# Note only secret variables are substituted. Environments variables are just written to a file and
# substituted at runtime by the continuous delivery tool running in cluster.
DEFAULT_VARS='${PING_IDENTITY_DEVOPS_USER_BASE64}
${PING_IDENTITY_DEVOPS_KEY_BASE64}
${SSH_ID_KEY_BASE64}'

VARS="${VARS:-${DEFAULT_VARS}}"

########################################################################################################################
# Add some derived environment variables to end of the provided environment file.
#
# Arguments
#   ${1} -> The name of the environment file.
########################################################################################################################
add_derived_variables() {
  local env_file="$1"

  add_comment_header_to_file "${CD_ENV_VARS}" 'Server profile variables'
  cat >> "${env_file}" <<EOF
SERVER_PROFILE_URL=\${CLUSTER_STATE_REPO_URL}
SERVER_PROFILE_BRANCH=\${CLUSTER_STATE_REPO_BRANCH}

EOF

  add_comment_header_to_file "${CD_ENV_VARS}" 'Public hostnames'
  cat >> "${env_file}" <<EOF
# Ping admin configuration required for admin access and clustering
PD_PRIMARY_PUBLIC_HOSTNAME=pingdirectory-admin.\${PRIMARY_DNS_ZONE}
PF_ADMIN_PUBLIC_HOSTNAME=pingfederate-admin.\${PRIMARY_DNS_ZONE}
PA_ADMIN_PUBLIC_HOSTNAME=pingaccess-admin.\${PRIMARY_DNS_ZONE}
PA_WAS_ADMIN_PUBLIC_HOSTNAME=pingaccess-was-admin.\${PRIMARY_DNS_ZONE}

PD_CLUSTER_PUBLIC_HOSTNAME=pingdirectory-cluster.\${PRIMARY_DNS_ZONE}
PF_CLUSTER_PUBLIC_HOSTNAME=pingfederate-cluster.\${PRIMARY_DNS_ZONE}
PA_CLUSTER_PUBLIC_HOSTNAME=pingaccess-cluster.\${PRIMARY_DNS_ZONE}
PA_WAS_CLUSTER_PUBLIC_HOSTNAME=pingaccess-was-cluster.\${PRIMARY_DNS_ZONE}

# Ping engine hostname variables
PD_PUBLIC_HOSTNAME=pingdirectory-admin.\${DNS_ZONE}
PF_ENGINE_PUBLIC_HOSTNAME=pingfederate.\${DNS_ZONE}
PA_ENGINE_PUBLIC_HOSTNAME=pingaccess.\${DNS_ZONE}
PA_WAS_ENGINE_PUBLIC_HOSTNAME=pingaccess-was.\${DNS_ZONE}

PROMETHEUS_PUBLIC_HOSTNAME=prometheus.\${DNS_ZONE}
GRAFANA_PUBLIC_HOSTNAME=monitoring.\${DNS_ZONE}
KIBANA_PUBLIC_HOSTNAME=logs.\${DNS_ZONE}
EOF
}

# Checking required tools and environment variables.
check_binaries "openssl" "ssh-keygen" "ssh-keyscan" "base64" "envsubst" "git"
HAS_REQUIRED_TOOLS=${?}

check_env_vars "PING_IDENTITY_DEVOPS_USER" "PING_IDENTITY_DEVOPS_KEY"
HAS_REQUIRED_VARS=${?}

if test ${HAS_REQUIRED_TOOLS} -ne 0 || test ${HAS_REQUIRED_VARS} -ne 0; then
  # Go back to previous working directory, if different, before exiting.
  popd >/dev/null 2>&1
  exit 1
fi

test -z "${IS_MULTI_CLUSTER}" && IS_MULTI_CLUSTER=false
if "${IS_MULTI_CLUSTER}"; then
  check_env_vars "CLUSTER_BUCKET_NAME"
  if test $? -ne 0; then
    popd >/dev/null 2>&1
    exit 1
  fi
fi

# Print out the values provided used for each variable.
echo "Initial TENANT_NAME: ${TENANT_NAME}"
echo "Initial SIZE: ${SIZE}"

echo "Initial IS_MULTI_CLUSTER: ${IS_MULTI_CLUSTER}"
echo "Initial CLUSTER_BUCKET_NAME: ${CLUSTER_BUCKET_NAME}"
echo "Initial REGION: ${REGION}"
echo "Initial REGION_NICK_NAME: ${REGION_NICK_NAME}"
echo "Initial PRIMARY_REGION: ${PRIMARY_REGION}"
echo "Initial TENANT_DOMAIN: ${TENANT_DOMAIN}"
echo "Initial PRIMARY_TENANT_DOMAIN: ${PRIMARY_TENANT_DOMAIN}"

echo "Initial CLUSTER_STATE_REPO_URL: ${CLUSTER_STATE_REPO_URL}"

echo "Initial ARTIFACT_REPO_URL: ${ARTIFACT_REPO_URL}"
echo "Initial PING_ARTIFACT_REPO_URL: ${PING_ARTIFACT_REPO_URL}"

echo "Initial LOG_ARCHIVE_URL: ${LOG_ARCHIVE_URL}"
echo "Initial BACKUP_URL: ${BACKUP_URL}"

echo "Initial K8S_GIT_URL: ${K8S_GIT_URL}"
echo "Initial K8S_GIT_BRANCH: ${K8S_GIT_BRANCH}"

echo "Initial REGISTRY_NAME: ${REGISTRY_NAME}"

echo "Initial SSH_ID_PUB_FILE: ${SSH_ID_PUB_FILE}"
echo "Initial SSH_ID_KEY_FILE: ${SSH_ID_KEY_FILE}"

echo "Initial TARGET_DIR: ${TARGET_DIR}"
echo "Initial IS_BELUGA_ENV: ${IS_BELUGA_ENV}"
echo ---

# Use defaults for other variables, if not present.
CD_COMMON_VARS="$(mktemp)"
echo "Writing CD common variables to file '${CD_COMMON_VARS}'"

export IS_BELUGA_ENV="${IS_BELUGA_ENV:-false}"
export TENANT_NAME="${TENANT_NAME:-ci-cd}"
export SIZE="${SIZE:-small}"

add_comment_header_to_file "${CD_COMMON_VARS}" 'Multi-region parameters'
export_variable_ln "${CD_COMMON_VARS}" IS_MULTI_CLUSTER "${IS_MULTI_CLUSTER}"

add_comment_to_file "${CD_COMMON_VARS}" 'S3 bucket name for PingFederate adaptive clustering'
add_comment_to_file "${CD_COMMON_VARS}" 'Only required in multi-cluster environments'
export_variable_ln "${CD_COMMON_VARS}" CLUSTER_BUCKET_NAME "${CLUSTER_BUCKET_NAME}"

add_comment_to_file "${CD_COMMON_VARS}" 'Region name, nick name and primary region name'
add_comment_to_file "${CD_COMMON_VARS}" 'REGION and PRIMARY_REGION must be valid AWS region names'
add_comment_to_file "${CD_COMMON_VARS}" 'Primary region should have the same value for REGION and PRIMARY_REGION'
export_variable "${CD_COMMON_VARS}" REGION "${REGION:-us-east-2}"
export_variable "${CD_COMMON_VARS}" REGION_NICK_NAME "${REGION_NICK_NAME:-${REGION}}"
export_variable_ln "${CD_COMMON_VARS}" PRIMARY_REGION "${PRIMARY_REGION:-${REGION}}"

add_comment_to_file "${CD_COMMON_VARS}" 'Tenant domain and primary tenant domain suffix for customer for region'
add_comment_to_file "${CD_COMMON_VARS}" 'Primary region should have the same value for TENANT_DOMAIN and PRIMARY_TENANT_DOMAIN'
TENANT_DOMAIN_NO_DOT_SUFFIX="${TENANT_DOMAIN%.}"
export_variable "${CD_COMMON_VARS}" TENANT_DOMAIN "${TENANT_DOMAIN_NO_DOT_SUFFIX:-ci-cd.ping-oasis.com}"
PRIMARY_TENANT_DOMAIN_NO_DOT_SUFFIX="${PRIMARY_TENANT_DOMAIN%.}"
export_variable_ln "${CD_COMMON_VARS}" PRIMARY_TENANT_DOMAIN "${PRIMARY_TENANT_DOMAIN_NO_DOT_SUFFIX:-${TENANT_DOMAIN}}"

add_comment_to_file "${CD_COMMON_VARS}" 'Region independent URL used for DNS failover/routing'   
if "${IS_BELUGA_ENV}"; then
   export_variable "${CD_COMMON_VARS}" GLOBAL_TENANT_DOMAIN "global.${TENANT_DOMAIN}"
else
   export_variable "${CD_COMMON_VARS}" GLOBAL_TENANT_DOMAIN "$(echo "${TENANT_DOMAIN}"|sed -e "s/\([^.]*\).[^.]*.\(.*\)/global.\1.\2/")"
fi

add_comment_header_to_file "${CD_COMMON_VARS}" 'S3 buckets'

add_comment_to_file "${CD_COMMON_VARS}" 'Customer-specific artifacts URL for region'
export_variable_ln "${CD_COMMON_VARS}" ARTIFACT_REPO_URL "${ARTIFACT_REPO_URL:-unused}"

add_comment_to_file "${CD_COMMON_VARS}" 'Ping-hosted common artifacts URL'
export_variable_ln "${CD_COMMON_VARS}" PING_ARTIFACT_REPO_URL \
  "${PING_ARTIFACT_REPO_URL:-https://ping-artifacts.s3-us-west-2.amazonaws.com}"

add_comment_to_file "${CD_COMMON_VARS}" 'Customer-specific log and backup URLs for region'
export_variable "${CD_COMMON_VARS}" LOG_ARCHIVE_URL "${LOG_ARCHIVE_URL:-unused}"
export_variable_ln "${CD_COMMON_VARS}" BACKUP_URL "${BACKUP_URL:-unused}"

add_comment_header_to_file "${CD_COMMON_VARS}" 'Miscellaneous ping-cloud-base variables'
add_comment_to_file "${CD_COMMON_VARS}" 'Namespace where Ping apps are deployed'
export_variable_ln "${CD_COMMON_VARS}" PING_CLOUD_NAMESPACE 'ping-cloud'

PING_CLOUD_BASE_COMMIT_SHA=$(git rev-parse HEAD)
CURRENT_GIT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
test "${CURRENT_GIT_BRANCH}" = 'HEAD' && CURRENT_GIT_BRANCH=$(git describe --tags --always)

add_comment_to_file "${CD_COMMON_VARS}" 'The ping-cloud-base git URL and branch for base Kubernetes manifests'
export_variable "${CD_COMMON_VARS}" K8S_GIT_URL "${K8S_GIT_URL:-https://github.com/pingidentity/ping-cloud-base}"
export_variable_ln "${CD_COMMON_VARS}" K8S_GIT_BRANCH "${K8S_GIT_BRANCH:-${CURRENT_GIT_BRANCH}}"

add_comment_to_file "${CD_COMMON_VARS}" 'The name of the Docker image registry'
export_variable_ln "${CD_COMMON_VARS}" REGISTRY_NAME "${REGISTRY_NAME:-docker.io}"

export SSH_ID_PUB_FILE="${SSH_ID_PUB_FILE}"
export SSH_ID_KEY_FILE="${SSH_ID_KEY_FILE}"

export TARGET_DIR="${TARGET_DIR:-/tmp/sandbox}"

# Print out the values being used for each variable.
echo "Using TENANT_NAME: ${TENANT_NAME}"
echo "Using SIZE: ${SIZE}"

echo "Using IS_MULTI_CLUSTER: ${IS_MULTI_CLUSTER}"
echo "Using CLUSTER_BUCKET_NAME: ${CLUSTER_BUCKET_NAME}"
echo "Using REGION: ${REGION}"
echo "Using REGION_NICK_NAME: ${REGION_NICK_NAME}"
echo "Using PRIMARY_REGION: ${PRIMARY_REGION}"
echo "Using TENANT_DOMAIN: ${TENANT_DOMAIN}"
echo "Using PRIMARY_TENANT_DOMAIN: ${PRIMARY_TENANT_DOMAIN}"

echo "Using CLUSTER_STATE_REPO_URL: ${CLUSTER_STATE_REPO_URL}"

echo "Using ARTIFACT_REPO_URL: ${ARTIFACT_REPO_URL}"
echo "Using PING_ARTIFACT_REPO_URL: ${PING_ARTIFACT_REPO_URL}"

echo "Using K8S_GIT_URL: ${K8S_GIT_URL}"
echo "Using K8S_GIT_BRANCH: ${K8S_GIT_BRANCH}"

echo "Using REGISTRY_NAME: ${REGISTRY_NAME}"

echo "Using SSH_ID_PUB_FILE: ${SSH_ID_PUB_FILE}"
echo "Using SSH_ID_KEY_FILE: ${SSH_ID_KEY_FILE}"

echo "Using TARGET_DIR: ${TARGET_DIR}"
echo "Using IS_BELUGA_ENV: ${IS_BELUGA_ENV}"
echo ---

export PING_IDENTITY_DEVOPS_USER_BASE64=$(base64_no_newlines "${PING_IDENTITY_DEVOPS_USER}")
export PING_IDENTITY_DEVOPS_KEY_BASE64=$(base64_no_newlines "${PING_IDENTITY_DEVOPS_KEY}")

TEMPLATES_HOME="${SCRIPT_HOME}/templates"
BASE_DIR="${TEMPLATES_HOME}/base"
BASE_TOOLS_REL_DIR="base/cluster-tools"
BASE_PING_CLOUD_REL_DIR="base/ping-cloud"

REGION_DIR="${TEMPLATES_HOME}/region"
REGION_TOOLS_REL_DIR="${REGION_NICK_NAME}/cluster-tools"
REGION_PING_CLOUD_REL_DIR="${REGION_NICK_NAME}/ping-cloud"

# Generate an SSH key pair for flux CD.
if test -z "${SSH_ID_PUB_FILE}" && test -z "${SSH_ID_KEY_FILE}"; then
  echo 'Generating key-pair for SSH access'
  generate_ssh_key_pair
elif test -z "${SSH_ID_PUB_FILE}" || test -z "${SSH_ID_KEY_FILE}"; then
  echo 'Provide SSH key-pair files via SSH_ID_PUB_FILE/SSH_ID_KEY_FILE env vars, or omit both for key-pair to be generated'
  exit 1
else
  echo 'Using provided key-pair for SSH access'
  export SSH_ID_PUB=$(cat "${SSH_ID_PUB_FILE}")
  export SSH_ID_KEY_BASE64=$(base64_no_newlines "${SSH_ID_KEY_FILE}")
fi

# Get the known hosts contents for the cluster state repo host to pass it into flux.
parse_url "${CLUSTER_STATE_REPO_URL}"
echo "Obtaining known_hosts contents for cluster state repo host: ${URL_HOST}"

add_comment_header_to_file "${CD_COMMON_VARS}" 'Cluster state repo details'
add_comment_to_file "${CD_COMMON_VARS}" 'The known-hosts file to trust the cluster state repo server for git/ssh cloning'
export_variable_ln "${CD_COMMON_VARS}" KNOWN_HOSTS_CLUSTER_STATE_REPO "$(ssh-keyscan -H "${URL_HOST}" 2>/dev/null)" true

# Delete existing target directory and re-create it
rm -rf "${TARGET_DIR}"
mkdir -p "${TARGET_DIR}"

# Next build up the directory structure of the cluster-state repo
FLUXCD_DIR="${TARGET_DIR}/fluxcd"
CLUSTER_STATE_DIR="${TARGET_DIR}/cluster-state"
K8S_CONFIGS_DIR="${CLUSTER_STATE_DIR}/k8s-configs"

mkdir -p "${FLUXCD_DIR}"
mkdir -p "${K8S_CONFIGS_DIR}"

cp ../.gitignore "${CLUSTER_STATE_DIR}"
cp ../k8s-configs/cluster-tools/git-ops/flux/flux-command.sh "${K8S_CONFIGS_DIR}"
find "${TEMPLATES_HOME}" -type f -maxdepth 1 | xargs -I {} cp {} "${K8S_CONFIGS_DIR}"

cp -pr ../profiles/aws/. "${CLUSTER_STATE_DIR}"/profiles
echo "${PING_CLOUD_BASE_COMMIT_SHA}" > "${TARGET_DIR}/pcb-commit-sha.txt"

# Now generate the yaml files for each environment
ENVIRONMENTS='dev test stage prod'

export_variable "${CD_COMMON_VARS}" CLUSTER_STATE_REPO_URL \
  "${CLUSTER_STATE_REPO_URL:-git@github.com:pingidentity/ping-cloud-base.git}"

for ENV in ${ENVIRONMENTS}; do
  CD_ENV_VARS="$(mktemp)"
  cp "${CD_COMMON_VARS}" "${CD_ENV_VARS}"

  # Export all the environment variables required for envsubst
  test "${ENV}" = 'prod' &&
    export_variable "${CD_ENV_VARS}" CLUSTER_STATE_REPO_BRANCH 'master' ||
    export_variable "${CD_ENV_VARS}" CLUSTER_STATE_REPO_BRANCH "${ENV}"
  export_variable_ln "${CD_ENV_VARS}" CLUSTER_STATE_REPO_PATH "${REGION_NICK_NAME}"

  add_comment_header_to_file "${CD_ENV_VARS}" 'Environment-specific variables'
  add_comment_to_file "${CD_ENV_VARS}" 'Used by server profile hooks'
  export_variable_ln "${CD_ENV_VARS}" ENVIRONMENT_TYPE "${ENV}"

  add_comment_to_file "${CD_ENV_VARS}" 'Used by Kubernetes manifests'
  export_variable "${CD_ENV_VARS}" ENV "${ENV}"

  # The base URL for kustomization files and environment will be different for each CDE.
  case "${ENV}" in
    dev | test)
      export_variable_ln "${CD_ENV_VARS}" KUSTOMIZE_BASE 'test'
      ;;
    stage)
      export_variable_ln "${CD_ENV_VARS}" KUSTOMIZE_BASE 'prod/small'
      ;;
    prod)
      export_variable_ln "${CD_ENV_VARS}" KUSTOMIZE_BASE "prod/${SIZE}"
      ;;
  esac

  # Update the Let's encrypt server to use staging/production based on environment type.
  add_comment_header_to_file "${CD_ENV_VARS}" 'Lets Encrypt server'
  case "${ENV}" in
    dev | test | stage)
      export_variable_ln "${CD_ENV_VARS}" LETS_ENCRYPT_SERVER 'https://acme-staging-v02.api.letsencrypt.org/directory'
      ;;
    prod)
      export_variable_ln "${CD_ENV_VARS}" LETS_ENCRYPT_SERVER 'https://acme-v02.api.letsencrypt.org/directory'
      ;;
  esac

  # Set PF variables based on ENV
  add_comment_header_to_file "${CD_ENV_VARS}" 'PingFederate variables for environment'
  case "${ENV}" in
    dev | test | stage)
      export_variable "${CD_ENV_VARS}" PF_PD_BIND_PORT 1389
      export_variable "${CD_ENV_VARS}" PF_PD_BIND_PROTOCOL ldap
      export_variable_ln "${CD_ENV_VARS}" PF_PD_BIND_USESSL false
      ;;
    prod)
      export_variable "${CD_ENV_VARS}" PF_PD_BIND_PORT 5678
      export_variable "${CD_ENV_VARS}" PF_PD_BIND_PROTOCOL ldaps
      export_variable_ln "${CD_ENV_VARS}" PF_PD_BIND_USESSL true
      ;;
  esac

  # Update the PF JVM limits based on environment.
  case "${ENV}" in
    dev | test)
      export_variable "${CD_ENV_VARS}" PF_MIN_HEAP 1536m
      export_variable "${CD_ENV_VARS}" PF_MAX_HEAP 1536m
      export_variable "${CD_ENV_VARS}" PF_MIN_YGEN 768m
      export_variable_ln "${CD_ENV_VARS}" PF_MAX_YGEN 768m
      ;;
    stage | prod)
      export_variable "${CD_ENV_VARS}" PF_MIN_HEAP 3072m
      export_variable "${CD_ENV_VARS}" PF_MAX_HEAP 3072m
      export_variable "${CD_ENV_VARS}" PF_MIN_YGEN 1536m
      export_variable_ln "${CD_ENV_VARS}" PF_MAX_YGEN 1536m
      ;;
  esac

  # FIXME: PA/PA-WAS heap settings should be made variables

  add_comment_header_to_file "${CD_ENV_VARS}" 'Cluster name variables'
  if "${IS_BELUGA_ENV}"; then
    export_variable "${CD_ENV_VARS}" CLUSTER_NAME "${TENANT_NAME}"
  else
    export_variable "${CD_ENV_VARS}" CLUSTER_NAME "${ENV}"
  fi

  CLUSTER_NAME_LC="$(echo "${CLUSTER_NAME}" | tr '[:upper:]' '[:lower:]')"
  export_variable_ln "${CD_ENV_VARS}" CLUSTER_NAME_LC "${CLUSTER_NAME_LC}"

  add_comment_header_to_file "${CD_ENV_VARS}" 'DNS zones'
  if "${IS_BELUGA_ENV}"; then
    export_variable "${CD_ENV_VARS}" DNS_ZONE "\${TENANT_DOMAIN}"
    export_variable_ln "${CD_ENV_VARS}" PRIMARY_DNS_ZONE "\${PRIMARY_TENANT_DOMAIN}"
  else
    export_variable "${CD_ENV_VARS}" DNS_ZONE "\${ENV}-\${TENANT_DOMAIN}"
    export_variable_ln "${CD_ENV_VARS}" PRIMARY_DNS_ZONE "\${ENV}-\${PRIMARY_TENANT_DOMAIN}"
  fi

  add_derived_variables "${CD_ENV_VARS}"

  echo ---
  echo "Writing CD ${ENV}-specific variables to file '${CD_ENV_VARS}'"
  echo "For environment ${ENV}, using variable values:"
  echo "CLUSTER_STATE_REPO_BRANCH: ${CLUSTER_STATE_REPO_BRANCH}"
  echo "CLUSTER_STATE_REPO_PATH: ${CLUSTER_STATE_REPO_PATH}"
  echo "ENVIRONMENT_TYPE: ${ENVIRONMENT_TYPE}"
  echo "KUSTOMIZE_BASE: ${KUSTOMIZE_BASE}"
  echo "CLUSTER_NAME: ${CLUSTER_NAME}"
  echo "PING_CLOUD_NAMESPACE: ${PING_CLOUD_NAMESPACE}"
  echo "DNS_ZONE: ${DNS_ZONE}"
  echo "PRIMARY_DNS_ZONE: ${PRIMARY_DNS_ZONE}"
  echo "LOG_ARCHIVE_URL: ${LOG_ARCHIVE_URL}"
  echo "BACKUP_URL: ${BACKUP_URL}"

  # Build the flux kustomization file for each environment
  echo "Generating flux yaml"

  ENV_FLUX_DIR="${FLUXCD_DIR}/${ENV}"
  mkdir -p "${ENV_FLUX_DIR}"

  cp "${TEMPLATES_HOME}"/fluxcd/* "${ENV_FLUX_DIR}"

  # Create a list of variables to substitute for flux CD
  vars="$(grep -Ev "^$|#" "${CD_ENV_VARS}" | (cut -d= -f1; echo SSH_ID_KEY_BASE64) | awk '{ print "${" $1 "}" }')"
  substitute_vars "${ENV_FLUX_DIR}" "${vars}"

  # Copy the shared cluster tools and Ping yaml templates into their target directories
  echo "Generating tools and ping yaml"

  ENV_DIR="${K8S_CONFIGS_DIR}/${ENV}"
  mkdir -p "${ENV_DIR}"

  cp -r "${BASE_DIR}" "${ENV_DIR}"
  cp -r "${REGION_DIR}/." "${ENV_DIR}/${REGION_NICK_NAME}"
  cp "${CD_ENV_VARS}" "${ENV_DIR}/${REGION_NICK_NAME}/env_vars"

  substitute_vars "${ENV_DIR}" "${VARS}" orig-secrets.yaml

  # Regional enablement - add admins, backups, etc. to primary.
  if test "${TENANT_DOMAIN}" = "${PRIMARY_TENANT_DOMAIN}"; then
    PRIMARY_PING_KUST_FILE="${ENV_DIR}/${REGION_PING_CLOUD_REL_DIR}/kustomization.yaml"
    sed -i.bak 's/^\(.*remove-from-secondary-patch.yaml\)$/# \1/' "${PRIMARY_PING_KUST_FILE}"
    rm -f "${PRIMARY_PING_KUST_FILE}.bak"
  fi
done

cp -p push-cluster-state.sh "${TARGET_DIR}"

# Go back to previous working directory, if different
popd >/dev/null 2>&1

echo
echo '------------------------'
echo '|  Next steps to take  |'
echo '------------------------'
echo "1) Run ${TARGET_DIR}/push-cluster-state.sh to push the generated code into the tenant cluster-state repo:"
echo "${CLUSTER_STATE_REPO_URL}"
echo
echo "2) Add the following identity as the deploy key on the cluster-state (rw), if not already added:"
echo "${SSH_ID_PUB}"
echo
echo "3) Deploy flux onto each CDE by navigating to ${TARGET_DIR}/fluxcd and running:"
echo 'kustomize build | kubectl apply -f -'
