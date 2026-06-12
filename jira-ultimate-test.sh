#!/bin/bash

# =========================================================
# Jira all-in-one test script
#
# 1. Uses createmeta to inspect a project + issue type
# 2. Prints allowed and required fields
# 3. Creates a test issue with those settings
#
# Fill in ONLY the CONFIG section below.
# =========================================================

# ------------------- CONFIG - FILL THIS IN -------------------

# Jira base URL
# This must be the root of Jira only.
# Examples:
#   JIRA_BASE_URL="https://jira.example.com"
#   JIRA_BASE_URL="https://jira.example.com/jira"
# It must NOT contain /browse/... or an issue key.
JIRA_BASE_URL="https://jira.example.com"

# Jira Personal Access Token for the account that will create issues
# Put the real token here. Treat it like a password.
JIRA_PAT="PUT_YOUR_PAT_HERE"

# Jira project key where you want tickets created
# Example: "ITOPS"
PROJECT_KEY="ITOPS"

# Issue type NAME, exactly as shown in Jira UI for that project
# Example: "Incident" or "Task" or "Bug"
ISSUE_TYPE_NAME="Incident"

# Optional labels that will be applied to the test issue
# You can change the labels or leave as-is.
JIRA_LABELS='["nagios_test", "jira_api_test"]'

# Extra required fields for this project/issue type
# If createmeta shows additional required fields like customfield_12345,
# you must add them here as a JSON object.
#
# If you have no extra required fields, leave this as '{}'.
#
# Example for a required custom field "customfield_12022" that is a select list:
# EXTRA_FIELDS_JSON='{ "customfield_12022": { "name": "High" } }'
EXTRA_FIELDS_JSON='{}'

# Prefix for the test issue summary
TEST_SUMMARY_PREFIX="NagiosXI Jira API test"

# ------------------- END OF CONFIG -----------------------

# From here down, you should not need to edit anything.

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is not installed. Install jq and run again."
  exit 1
fi

if [ -z "$JIRA_BASE_URL" ] || [ -z "$JIRA_PAT" ] || [ -z "$PROJECT_KEY" ] || [ -z "$ISSUE_TYPE_NAME" ]; then
  echo "ERROR: One or more CONFIG values are empty. Check the CONFIG section at the top of this script."
  exit 1
fi

echo "== Step 1: Querying Jira createmeta =="
echo "Project key:    ${PROJECT_KEY}"
echo "Issue type name: ${ISSUE_TYPE_NAME}"
echo

CREATEMETA_URL="${JIRA_BASE_URL}/rest/api/2/issue/createmeta?projectKeys=${PROJECT_KEY}&issuetypeNames=$(printf '%s' "$ISSUE_TYPE_NAME" | sed 's/ /%20/g')&expand=projects.issuetypes.fields"

echo "DEBUG: createmeta URL:"
echo "  ${CREATEMETA_URL}"
echo

CREATEMETA_RESPONSE=$(curl -sS -w " HTTP_STATUS:%{http_code}" \
  -H "Authorization: Bearer ${JIRA_PAT}" \
  -H "Accept: application/json" \
  "${CREATEMETA_URL}" 2>&1)

CREATEMETA_BODY=$(printf '%s' "$CREATEMETA_RESPONSE" | sed -e 's/ HTTP_STATUS:.*//')
CREATEMETA_STATUS=$(printf '%s' "$CREATEMETA_RESPONSE" | sed -n 's/.*HTTP_STATUS://p')

echo "createmeta HTTP status: ${CREATEMETA_STATUS}"
echo

if [ "$CREATEMETA_STATUS" != "200" ]; then
  echo "ERROR: Jira createmeta returned a non 200 status. Raw response body:"
  echo "$CREATEMETA_BODY"
  exit 1
fi

ISSUE_INFO=$(echo "$CREATEMETA_BODY" | jq -r \
  --arg project "$PROJECT_KEY" \
  --arg itype "$ISSUE_TYPE_NAME" '
    .projects[]
    | select(.key == $project)
    | .issuetypes[]
    | select(.name == $itype)
  ')

if [ -z "$ISSUE_INFO" ] || [ "$ISSUE_INFO" = "null" ]; then
  echo "ERROR: Could not find issue type '$ISSUE_TYPE_NAME' in project '$PROJECT_KEY' in createmeta output."
  echo "Raw createmeta body for reference:"
  echo "$CREATEMETA_BODY"
  exit 1
fi

ISSUE_TYPE_ID=$(echo "$ISSUE_INFO" | jq -r '.id')
FIELDS_JSON=$(echo "$ISSUE_INFO" | jq -r '.fields')

echo "Issue type ID detected from Jira: ${ISSUE_TYPE_ID}"
echo

HAS_SUMMARY=$(echo "$FIELDS_JSON" | jq 'has("summary")')
HAS_DESCRIPTION=$(echo "$FIELDS_JSON" | jq 'has("description")')

echo "Can Jira accept 'summary' for this project/issue type:     ${HAS_SUMMARY}"
echo "Can Jira accept 'description' for this project/issue type: ${HAS_DESCRIPTION}"
echo

echo "Required fields for Create (from createmeta):"
echo "$FIELDS_JSON" | jq -r '
  to_entries[]
  | select(.value.required == true)
  | "- " + .key
'
echo

EXTRA_REQUIRED_KEYS=$(echo "$FIELDS_JSON" | jq -r '
  to_entries[]
  | select(
      .value.required == true
      and .key != "project"
      and .key != "issuetype"
      and .key != "summary"
      and .key != "description"
    )
  | .key
')

if [ -n "$EXTRA_REQUIRED_KEYS" ]; then
  echo "There are additional required fields besides project, issuetype, summary, and description:"
  echo "$EXTRA_REQUIRED_KEYS" | sed 's/^/  - /'
  echo
else
  echo "No additional required fields beyond project, issuetype, summary, description."
  echo
fi

MISSING_KEYS=""
if [ -n "$EXTRA_REQUIRED_KEYS" ]; then
  echo "Checking if EXTRA_FIELDS_JSON covers all additional required fields..."
  for k in $EXTRA_REQUIRED_KEYS; do
    HAS_KEY=$(echo "$EXTRA_FIELDS_JSON" | jq -r --arg key "$k" 'has($key)')
    if [ "$HAS_KEY" != "true" ]; then
      MISSING_KEYS="${MISSING_KEYS}${k} "
    fi
  done
fi

if [ -n "$MISSING_KEYS" ]; then
  echo "ERROR: These required fields are not present in EXTRA_FIELDS_JSON:"
  for k in $MISSING_KEYS; do
    echo "  - $k"
  done
  echo
  echo "Edit EXTRA_FIELDS_JSON in the CONFIG section at the top of this script and add values for these keys."
  echo "Then run this script again."
  exit 1
fi

if [ "$HAS_SUMMARY" != "true" ] || [ "$HAS_DESCRIPTION" != "true" ]; then
  echo "WARNING: createmeta reports that summary and/or description are not allowed."
  echo "This usually means they are not on the Create screen for this project and issue type."
  echo "Ticket creation will likely fail with 'Field ... cannot be set' until Jira configuration is fixed."
  echo
fi

echo "== Step 2: Creating a test issue =="

NOW_HUMAN=$(date)
SUMMARY="${TEST_SUMMARY_PREFIX} - ${NOW_HUMAN}"

DESCRIPTION=$(cat <<EOF
This is a test issue created by jira_allinone_test.sh.

Project: ${PROJECT_KEY}
Issue type name: ${ISSUE_TYPE_NAME}
Issue type ID: ${ISSUE_TYPE_ID}
Time: ${NOW_HUMAN}

If you see this issue in Jira, the REST API create operation is working for this project and issue type.
EOF
)

JSON_PAYLOAD=$(jq -n \
  --arg project "$PROJECT_KEY" \
  --arg summary "$SUMMARY" \
  --arg description "$DESCRIPTION" \
  --arg issuetype_id "$ISSUE_TYPE_ID" \
  --argjson labels "$JIRA_LABELS" \
  --argjson extra "$EXTRA_FIELDS_JSON" '
  {
    fields:
      (
        {
          project:  { key: $project },
          summary:  $summary,
          description: $description,
          issuetype: { id: $issuetype_id },
          labels:   $labels
        } + $extra
      )
  }
')

CREATE_URL="${JIRA_BASE_URL}/rest/api/2/issue"

echo "DEBUG: create issue URL:"
echo "  ${CREATE_URL}"
echo

CREATE_RESPONSE=$(curl -sS -w " HTTP_STATUS:%{http_code}" \
  -H "Authorization: Bearer ${JIRA_PAT}" \
  -H "Content-Type: application/json" \
  -X POST "${CREATE_URL}" \
  -d "${JSON_PAYLOAD}" 2>&1)

CREATE_BODY=$(printf '%s' "$CREATE_RESPONSE" | sed -e 's/ HTTP_STATUS:.*//')
CREATE_STATUS=$(printf '%s' "$CREATE_RESPONSE" | sed -n 's/.*HTTP_STATUS://p')

echo "Create issue HTTP status: ${CREATE_STATUS}"
echo "Create issue response body:"
echo "$CREATE_BODY"
echo

if [ "$CREATE_STATUS" = "201" ]; then
  ISSUE_KEY=$(echo "$CREATE_BODY" | jq -r '.key // empty')
  if [ -n "$ISSUE_KEY" ]; then
    echo "SUCCESS: Created test issue with key: ${ISSUE_KEY}"
  else
    echo "SUCCESS: Issue created, but could not parse issue key from response."
  fi
else
  echo "Issue was not created with HTTP 201. Use the response body above to see which fields Jira is complaining about."
fi
