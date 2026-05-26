#!/usr/bin/env bash
set -euo pipefail

db_init(){ [ -f "$DB_FILE" ] || echo '{}' > "$DB_FILE"; [ -f "$SERVICES_FILE" ] || echo '[]' > "$SERVICES_FILE"; }

db_count(){ python3 - "$DB_FILE" <<'PY'
import json,sys
print(len([k for k in json.load(open(sys.argv[1])) if not k.startswith('__')]))
PY
}
svc_count(){ python3 - "$SERVICES_FILE" <<'PY'
import json,sys
print(len(json.load(open(sys.argv[1]))))
PY
}
svc_add(){
  python3 - "$SERVICES_FILE" "$1" "$2" "$3" "$4" <<'PY'
import json,sys
p,n,d,t,m=sys.argv[1:]
arr=json.load(open(p))
for s in arr:
  if s['name']==n:
    s.update({'domain':d,'target':t,'mode':m}); break
else:
  arr.append({'name':n,'domain':d,'target':t,'mode':m})
json.dump(arr,open(p,'w'),indent=2)
PY
}
svc_list(){ python3 - "$SERVICES_FILE" <<'PY'
import json,sys
for i,s in enumerate(json.load(open(sys.argv[1])),1):
 print(f"{i}) {s['name']} | {s.get('domain','')} | {s.get('mode','new')}")
PY
}
