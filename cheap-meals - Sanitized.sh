#!/bin/bash
# =============================================================================
# cheap-meals.sh
# Queries ezcater meal program and prints items under $2.60 for all
# available days (typically today + next 2-3 days).
#
# Requirements: curl, jq
#   Install jq on Mac:    brew install jq
#   Install jq on Linux:  sudo apt install jq / sudo yum install jq
#
# To run daily automatically:
#   crontab -e
#   Add: 0 8 * * * /path/to/cheap-meals.sh >> /path/to/cheap-meals.log 2>&1
# =============================================================================

THRESHOLD_CENTS=260
ENDPOINT="https://mealprogram.ezcater.com/graphql"

# --- Update these cookies when the script stops working ---
COOKIE='referrer_url=; tid=; _gcl_au=; rl_anonymous_id='

CURL_ARGS=(-sk -H "Cookie: $COOKIE" -H "Content-Type: application/json" -H "Accept: application/json")

gql() {
  curl "${CURL_ARGS[@]}" -X POST "$ENDPOINT" -d "$1"
}

# ---------------------------------------------------------------
# Step 1: Fetch the full schedule (all available days), including store ID
# ---------------------------------------------------------------
SCHEDULE_RESP=$(gql '{"query":"{ schedule { date scheduleEntries { id store { id name } cutoffAt availabilityStatus } } }"}')

if ! echo "$SCHEDULE_RESP" | jq -e '.data.schedule' > /dev/null 2>&1; then
  echo "ERROR: Failed to fetch schedule. Cookie may be expired."
  echo "Response: $SCHEDULE_RESP"
  exit 1
fi

THRESHOLD_DOLLARS=$(echo "scale=2; $THRESHOLD_CENTS/100" | bc)
DAY_COUNT=$(echo "$SCHEDULE_RESP" | jq '.data.schedule | length')

echo "============================================================"
echo " ezcater Cheap Meals (under \$$THRESHOLD_DOLLARS)"
echo " Run at: $(date)"
echo "============================================================"

# ---------------------------------------------------------------
# Step 2: Loop over every day and every restaurant entry
# ---------------------------------------------------------------
for day_i in $(seq 0 $((DAY_COUNT - 1))); do
  DATE=$(echo "$SCHEDULE_RESP" | jq -r ".data.schedule[$day_i].date")
  ENTRY_COUNT=$(echo "$SCHEDULE_RESP" | jq ".data.schedule[$day_i].scheduleEntries | length")

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo " $DATE"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  if [ "$ENTRY_COUNT" -eq 0 ]; then
    echo "  No entries scheduled."
    continue
  fi

  for entry_i in $(seq 0 $((ENTRY_COUNT - 1))); do
    ENTRY=$(echo "$SCHEDULE_RESP" | jq ".data.schedule[$day_i].scheduleEntries[$entry_i]")
    ENTRY_ID=$(echo "$ENTRY" | jq -r '.id')
    STORE_ID=$(echo "$ENTRY" | jq -r '.store.id')
    STORE_NAME=$(echo "$ENTRY" | jq -r '.store.name')
    CUTOFF=$(echo "$ENTRY" | jq -r '.cutoffAt')
    STATUS=$(echo "$ENTRY" | jq -r '.availabilityStatus')

    echo ""
    echo "  $STORE_NAME  (order by: $CUTOFF | $STATUS)"

    # Build payload with jq to avoid escaping issues
    MENU_PAYLOAD=$(jq -n --arg eid "$ENTRY_ID" --arg sid "$STORE_ID" \
      '{"query":"{ menu(scheduleEntryId: \($eid), storeId: \($sid)) { categories { name items { name soldOut sizes { name price { subunits } } } } } }"}')

    MENU_RESP=$(gql "$MENU_PAYLOAD")

    if ! echo "$MENU_RESP" | jq -e '.data.menu.categories' > /dev/null 2>&1; then
      echo "    Could not fetch menu."
      continue
    fi

    CHEAP=$(echo "$MENU_RESP" | jq --argjson threshold "$THRESHOLD_CENTS" '
      .data.menu.categories[].items[]
      | select(.soldOut == false)
      | . as $item
      | .sizes[]
      | select(.price.subunits != null and .price.subunits < $threshold)
      | {
          item: $item.name,
          size: .name,
          cents: .price.subunits
        }
    ')

    if [ -z "$CHEAP" ]; then
      echo "    No items under \$$THRESHOLD_DOLLARS"
    else
      echo "$CHEAP" | jq -r '"    $\(.cents / 100 | tostring | if test("\\.") then split(".") | .[0]+"."+.[1][0:2] else .+".00" end)  \(.item)\(if .size and .size != "" then " (\(.size))" else "" end)"' | sort -t'$' -k2 -n
    fi
  done
done

echo ""
echo "============================================================"
echo "Done."
