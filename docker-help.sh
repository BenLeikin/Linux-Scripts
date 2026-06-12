# names/IDs and internal app ports
C1=working_container
P1=8080
C2=failing_container
P2=8080

echo "== Ports column =="
docker ps --format 'table {{.Names}}\t{{.Ports}}' | egrep "^($C1|$C2)\b"

echo "== Port bindings =="
for C in "$C1" "$C2"; do
  echo "-- $C"
  docker inspect "$C" --format '{{json .HostConfig.PortBindings}}'
done

echo "== Inside each container: listening sockets =="
for C in "$C1" "$C2"; do
  echo "-- $C"
  docker exec "$C" sh -lc 'command -v ss >/dev/null && ss -lntp || netstat -lntp'
done

echo "== Container IPs and published host ports =="
for C in "$C1" "$C2"; do
  CIP=$(docker inspect "$C" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
  HPORT=$(docker inspect "$C" --format '{{range $k,$v := .NetworkSettings.Ports}}{{if $v}}{{(index $v 0).HostPort}}{{end}}{{end}}')
  echo "$C CIP=$CIP HPORT=$HPORT"
done

echo "== Curl tests from host =="
# direct to container bridge IP
curl -sv --max-time 3 "http://$(docker inspect $C1 --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'):${P1}/" 2>&1 | sed -n '1,12p'
curl -sv --max-time 3 "http://$(docker inspect $C2 --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'):${P2}/" 2>&1 | sed -n '1,12p'
# to published host ports (if any)
for C in "$C1" "$C2"; do
  HPORT=$(docker inspect "$C" --format '{{range $k,$v := .NetworkSettings.Ports}}{{if $v}}{{(index $v 0).HostPort}}{{end}}{{end}}')
  if [ -n "$HPORT" ]; then
    echo "-- $C on host port $HPORT"
    curl -sv --max-time 3 "http://127.0.0.1:${HPORT}/" 2>&1 | sed -n '1,12p'
  else
    echo "-- $C has no published host port"
  fi
done
