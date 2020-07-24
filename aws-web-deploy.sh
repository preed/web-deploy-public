#!/bin/bash

set -e
#set -x

# Scrub PATH
export PATH="/sbin:/bin:/usr/sbin:/usr/bin"

# Tools

readonly AWSCLI="${AWSCLI:-aws}"

# Directories

readonly DEPLOYMENT_INFRA_DIR="$(realpath "$(dirname "$0")")"
readonly WEBROOT_DIR="${WEBROOT_DIR:-$PWD}"

# Other Config stuff

readonly REDIRECTS_FILE="$WEBROOT_DIR/redirects.txt"
readonly S3_WEBSITE_BUCKET_CONFIG="$WEBROOT_DIR/s3-website-bucket-config.json"
readonly GIT_BRANCH="$(cd $WEBROOT_DIR && git rev-parse --abbrev-ref HEAD)"

# There are two places we look for config files:
#  A .deploy-config stored _with_ the web content (useful if we want others to
#  be able to deploy the website themselves)
#
#  A website-name.com.deploy-config stored in this directory, which is useful
#  to centralize secrets (so others can work on the site, but not deploy it).

readonly WEBROOT_DEPLOY_DIR_CONFIG="$WEBROOT_DIR/.deploy-config"

readonly DEPLOYMENT_INFRA_DIR_DEPLOYMENT_CONFIG="$DEPLOYMENT_INFRA_DIR/$(cd $WEBROOT_DIR && git remote -v | grep ^origin | grep push | awk '{print $2}' | sed -E -e 's;(.*@)?github.com:preed/;;' | sed -e 's;.git$;;').deploy-config"

if [[ -f "$WEBROOT_DEPLOY_DIR_CONFIG" ]]; then
   . "$WEBROOT_DEPLOY_DIR_CONFIG"
elif [[ -f "$DEPLOYMENT_INFRA_DIR_DEPLOYMENT_CONFIG" ]]; then
   . "$DEPLOYMENT_INFRA_DIR_DEPLOYMENT_CONFIG"
else
   echo "Cannot find a valid deployment configuration file. Bailing." >&2
   exit 1
fi

if [[ -z "$WEBROOT_DEPLOY_DIR" ]]; then
   readonly WEBROOT_DEPLOY_DIR="$WEBROOT_DIR/out"
fi

#
# Variables the config files _must_ set
#   AWS_CONFIG_FILE - The aws tool config file with the secrets to use for this
#     site.
#
#   $env_S3_BUCKET - The S3 bucket to use for this environment
#     (i.e. prod_S3_BUCKET, staging_S3_BUCKET, etc.)
#
#
# Optional variables:
#
# DEFAULT_DEPLOYMENT_ENV - if the site isn't worth having a preprod env, you
#   can hardcode a default deployment env (probably prod)
#
# $env_CF_DIST_ID - The Cloudfront distribution ID to use for this
#   environment. If one is set, the script will flush it upon a deployment.
#

if [[ ! -f "$AWS_CONFIG_FILE" ]]; then
   echo "Unable to find site deployment AWS tool config: $AWS_CONFIG_FILE; bailing." >&2
   exit 1
fi

if [[ -n "$1" ]]; then
   deploy_env="$1"
elif [[ -n "$DEFAULT_DEPLOYMENT_ENV" ]]; then
   deploy_env="$DEFAULT_DEPLOYMENT_ENV"
else
   echo "Deployment environment must be specified (either in the config or on the commandline; bailing." >&2
   exit 1
fi

export AWS_DEFAULT_PROFILE="$deploy_env"
s3_bucket_var="${deploy_env}_S3_BUCKET"
s3_bucket="${!s3_bucket_var}"

if [[ -z "$s3_bucket" ]]; then
   echo "Empty/invalid S3 bucket specified; bailing." >&2
   exit 1
fi

if [[ ! -d "$WEBROOT_DEPLOY_DIR" ]]; then
   echo "Empty/invalid WEBROOT_DEPLOY_DIR: $WEBROOT_DEPLOY_DIR; bailing." >&2
   exit 1

fi

echo "Deploying directory: $WEBROOT_DEPLOY_DIR"
echo "Deployment profile: $deploy_env"
echo "Deploying to S3 bucket: $s3_bucket"
echo
echo "Deploying Git branch: $GIT_BRANCH"
echo "OK? (ctrl-c for no)"

read

export AWS_CONFIG_FILE

readonly version_file="$WEBROOT_DEPLOY_DIR/VERSION"

rm -f $version_file

readonly git_head_sha="$(git rev-parse --verify HEAD)"
readonly git_status="$(git status -s)"

if [[ -n "$git_status" ]]; then
   readonly git_version_string="${git_head_sha}-DIRTY"
else
   readonly git_version_string="${git_head_sha}"
fi

echo "$(date +%s)-$git_version_string" > $version_file

echo "Deploying Git version: $git_version_string"

SITE_CONFIGURED_EXCLUDES=""
if [[ -n "$S3_SYNC_EXCLUDES" ]]; then
   SITE_CONFIGURED_EXCLUDES="--exclude "
   for excl in $S3_SYNC_EXCLUDES; do
      SITE_CONFIGURED_EXCLUDES="$SITE_CONFIGURED_EXCLUDES $excl"
   done
fi

pushd $WEBROOT_DEPLOY_DIR > /dev/null

$AWSCLI \
   s3 \
   sync \
   --acl public-read \
   --delete \
   --exclude '.git/*' \
   --exclude '.gitignore' \
   --exclude '.deploy-config' \
   $SITE_CONFIGURED_EXCLUDES \
   . \
   s3://${s3_bucket}/

$AWSCLI \
   s3 \
   cp \
   --acl public-read \
   --cache-control 'no-cache' \
   --content-type text/plain \
   $version_file \
   s3://${s3_bucket}/

popd > /dev/null

if [[ -f "$REDIRECTS_FILE" ]]; then
   while read -r line; do
      # skip comment lines
      if [[ -n "$(echo "$line" | grep '^\s*#')" ]]; then
         continue
      # skip empty lines
      elif [[ -z "$(echo "$line" | sed -e 's:[ \t]::g')" ]]; then
         continue
      elif [[ -n "$(echo "$line" | grep '^\s*/')" ]]; then
         echo "INVALID REDIRECT: source contains leading slash; skipping: $line" >&2
         continue
      fi

      redirect_src="$(echo "$line" | awk '{print $1}')"
      redirect_tgt="$(echo "$line" | awk '{print $2}')"

      if [[ -z "$(echo "$redirect_tgt" | grep -i -E '^(https?://|/)')" ]]; then
         echo "INVALID REDIRECT: S3 requires a target with http[s] or a rooted path; skipping: $line" >&2
         continue
      fi

      echo "Deploying redirect: $redirect_src -> $redirect_tgt"

      $AWSCLI \
         s3api \
         put-object \
         --acl public-read \
         --website-redirect-location $redirect_tgt \
         --bucket $s3_bucket \
         --key $redirect_src
      echo
   done < "$REDIRECTS_FILE"
fi

if [[ -f "$S3_WEBSITE_BUCKET_CONFIG" ]]; then
   echo "Deploying S3 Website Bucket configuration: $S3_WEBSITE_BUCKET_CONFIG..."
   $AWSCLI \
      s3api \
      put-bucket-website \
      --bucket $s3_bucket \
      --website-configuration file://$S3_WEBSITE_BUCKET_CONFIG
fi

cf_dist_id_var="${deploy_env}_CF_DIST_ID"
cf_dist_id="${!cf_dist_id_var}"

if [[ -n "$cf_dist_id" ]]; then
   echo "Ready to invalidate CloudFront cache. Press ctrl-c to halt."
   read

   $AWSCLI \
      cloudfront \
      create-invalidation \
      --distribution-id "$cf_dist_id" \
      --paths '/*'
   echo
fi

env_url_var="${deploy_env}_URL"
env_url="${!env_url_var}"

if [[ -z "$env_url" ]]; then
   env_url="** UNSET; set $env_url_var **"
fi

echo
echo "Check the $deploy_env site at: $env_url"
echo
echo "DEPLOYMENT COMPLETED."
