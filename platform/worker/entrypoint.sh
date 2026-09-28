#!/bin/sh
set -eu

if [ -n "${GIT_WORK_NAME:-}" ]; then git config --global user.name "$GIT_WORK_NAME"; fi
if [ -n "${GIT_WORK_EMAIL:-}" ]; then git config --global user.email "$GIT_WORK_EMAIL"; fi

# GitLab accepts a personal access token as basic auth with user oauth2;
# the header keeps the token out of remote URLs in cloned repositories.
if [ -n "${GITLAB_URL:-}" ] && [ -n "${GITLAB_TOKEN:-}" ]; then
  auth=$(printf 'oauth2:%s' "$GITLAB_TOKEN" | base64 | tr -d '\n')
  git config --global "http.${GITLAB_URL%/}/.extraHeader" "Authorization: Basic $auth"
fi

if [ -n "${ATLASSIAN_EMAIL:-}" ] && [ -n "${ATLASSIAN_API_TOKEN:-}" ]; then
  ATLASSIAN_BASIC_AUTH=$(printf '%s:%s' "$ATLASSIAN_EMAIL" "$ATLASSIAN_API_TOKEN" | base64 | tr -d '\n')
  export ATLASSIAN_BASIC_AUTH
fi

exec python /opt/worker/worker.py
