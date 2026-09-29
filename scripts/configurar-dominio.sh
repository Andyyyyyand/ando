#!/usr/bin/env bash
# Aponta praticasinclusivas.online (Hostinger) para o GitHub Pages.
# Uso: bash scripts/configurar-dominio.sh   (o token da Hostinger é pedido na hora e não é salvo)
set -euo pipefail

DOMINIO="praticasinclusivas.online"
API="https://developers.hostinger.com/api/dns/v1/zones/$DOMINIO"

read -rsp "Cole o token da Hostinger e aperte Enter: " TOKEN
echo
[ -n "$TOKEN" ] || { echo "Nenhum token colado."; exit 1; }

CABECALHOS=(-H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -H "Accept: application/json")

echo "Removendo registros AAAA antigos do domínio (se existirem)..."
curl -sS -o /dev/null -X DELETE "${CABECALHOS[@]}" "$API" \
  -d '{"filters":[{"name":"@","type":"AAAA"}]}' || true

echo "Apontando o domínio para o GitHub Pages..."
# overwrite=true troca só os registros com o mesmo nome e tipo (A @ e CNAME www);
# e-mail (MX), TXT e os demais continuam como estão.
RESPOSTA=$(curl -sS -w $'\n%{http_code}' -X PUT "${CABECALHOS[@]}" "$API" -d '{
  "overwrite": true,
  "zone": [
    {"name": "@", "type": "A", "ttl": 3600, "records": [
      {"content": "185.199.108.153"},
      {"content": "185.199.109.153"},
      {"content": "185.199.110.153"},
      {"content": "185.199.111.153"}
    ]},
    {"name": "www", "type": "CNAME", "ttl": 3600, "records": [
      {"content": "andyyyyyand.github.io"}
    ]}
  ]
}')
CODIGO="${RESPOSTA##*$'\n'}"
CORPO="${RESPOSTA%$'\n'*}"

if [ "$CODIGO" != "200" ]; then
  echo "Deu erro (código $CODIGO). Mande esta mensagem para o Claude:"
  echo "$CORPO"
  exit 1
fi

echo "Pronto! Registros atuais do domínio:"
curl -sS "${CABECALHOS[@]}" "$API" \
  | grep -oE '"(name|type|content)":"[^"]*"' | sed 's/"//g' || true

echo
echo "Agora é só esperar de 30 minutos a algumas horas e abrir https://$DOMINIO"
echo "Depois apague o token em https://hpanel.hostinger.com/profile/api"
