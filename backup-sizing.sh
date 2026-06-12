#!/usr/bin/env bash
# backup_size_report.sh
# Measure total used space on all mounts and project future needs

LOGFILE="/var/log/backup_size.log"

# convert bytes to human-readable
human(){
  local b=$1
  if   [ $b -ge $((1024**3)) ]; then printf "%.2f GB" "$(bc -l <<<"$b/1024^3")"
  elif [ $b -ge $((1024**2)) ]; then printf "%.2f MB" "$(bc -l <<<"$b/1024^2")"
  elif [ $b -ge 1024        ]; then printf "%.2f KB" "$(bc -l <<<"$b/1024")"
  else  printf "%d B"   "$b"
  fi
}

# 1) raw used space
echo -n "Current used space on all mounts: "
RAW=$(df --total -B1 --output=used | tail -1)
echo "$(human $RAW)"

# append to history
echo "$(date +%F) $RAW" >> "$LOGFILE"

# 2) future forecasting
echo -e "\nProjected needs:"
for pct in 20 25 30 50; do
  FUT=$(awk "BEGIN{printf \"%d\", $RAW*(1+$pct/100)}")
  echo "  +${pct}% → $(human $FUT)"
done
