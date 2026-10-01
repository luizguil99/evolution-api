---
name: whatsapp-proxy
description: Escolher, comprar, validar e configurar proxies para instâncias WhatsApp (Baileys) do Evolution API. Use quando instâncias desconectam, aparece "atividade incomum", é preciso comprar/trocar proxy, adicionar IPs ao PROXY_POOL ou consultar quais proxies estão em uso.
---

# Proxies para WhatsApp (Evolution API / Baileys)

## Problema
A VPS fica fora do Brasil (França). Conectar números brasileiros direto do IP da VPS (datacenter estrangeiro)
gera "atividade incomum". Com proxy **residencial rotativo/sticky** (cobrado por GB) a instância **desconecta**:
o IP pertence ao roteador/celular de terceiros, cai quando o aparelho sai do ar, e a reconexão sai por outro IP.
Além disso o tráfego por GB acaba e derruba todas as instâncias juntas.

## Solução
Usar **proxy ISP / Static Residential do Brasil**: IP fixo, dedicado, tráfego ilimitado, registrado em
**ASN de provedor brasileiro** (não datacenter). Regra: **1 IP por número** (máx. 3 por IP só para atendimento;
disparo em massa = sempre 1).

## Onde comprar
| Fornecedor | Link | Observação |
|---|---|---|
| **NodeMaven ISP (usado hoje)** ✅ | https://dashboard.nodemaven.com/isp-proxies | Brasil ~US$ 4,99/IP/30d, mín. 3 IPs no pedido padrão. 1 swap grátis por pedido. Compra só pelo painel (API não compra). Testado: AS10704 ML Telecom, `hosting:false` |
| IPRoyal ISP | https://iproyal.com/isp-proxies/ | ~US$ 2,70/IP/30d; API compra com saldo (`POST https://apid.iproyal.com/v1/reseller/orders`, sem `card_id`) — **validar ASN antes** |
| Proxy-Seller ISP | https://proxy-seller.com/brazilian-proxy/ | ❌ Testado: IPs BR eram **AS9009 M247 / Ace Data Centers (`hosting:true`)**. Não serve. Reembolso 24h via chat |
| Proxy Brasil / ShieldProx / GTI | https://www.proxybrasil.com · https://shieldprox.com.br · https://gtiproxy.com | Fornecedores BR (Pix). Sem API de compra |

Ao comprar: tipo **ISP/Static**, país **Brazil**, protocolo **HTTP**, plano 30 ou 90 dias.
**NÃO** marcar opções de "100% uptime / automatic IP replacement" (troca o IP sozinho → ruim para WhatsApp).
Na NodeMaven, dados ficam em *ISP proxies → My proxies → Details* (IP, porta, usuário, senha, botão Swap).

## Validar um IP antes de usar (obrigatório)
```bash
P="http://USER:PASS@IP:PORT"
curl -s -m 20 -x "$P" https://ipinfo.io/json                       # país BR, org = provedor
curl -s "http://ip-api.com/json/IP?fields=isp,org,as,hosting,proxy,mobile"   # hosting deve ser false
r=$(echo IP | awk -F. '{print $4"."$3"."$2"."$1}'); for bl in zen.spamhaus.org bl.spamcop.net b.barracudacentral.org; do dig +short $r.$bl; done   # vazio = limpo
curl -s -o /dev/null -w "%{time_total}\n" -x "$P" https://web.whatsapp.com
```
Reprovar se: `hosting:true`, ASN de hospedagem (M247, OVH, Hetzner, "Data Center", "Hosting"), ou listado em blacklist.
Se reprovar na NodeMaven → usar o **Swap** (só 1 por pedido). Não gastar o swap à toa.

## Configurar no Evolution
`.env`:
```
# formato: host:porta:protocolo:usuario:senha  (separar entradas por vírgula ou quebra de linha)
PROXY_POOL=IP:PORT:http:USER:PASS,IP2:PORT:http:USER:PASS
```
- Protocolo: use só `http` ou `socks5`. `src/utils/makeProxyAgent.ts` **não suporta `https` nem `socks4`** (lança erro).
- `assignProxyFromPool` (`src/api/controllers/instance.controller.ts`) dá **1 proxy exclusivo por instância** ao criar; pool esgotado → erro "No free proxy left in PROXY_POOL".
- Instâncias antigas mantêm o proxy salvo no banco (tabela `Proxy`) mesmo se ele sair do `PROXY_POOL`.
  Para trocar: `POST /proxy/set/{instance}` com `{enabled,host,port,protocol,username,password}` e depois
  desconectar/reconectar o QR (evita o número "pular" de IP no meio da sessão).
- Reiniciar a API após mudar o `.env`.

## Consultar quais proxies estão em uso (API)
`GET /proxy/pool` com header `apikey: <AUTHENTICATION_API_KEY global>` → retorna
`{ total, inUse, free, proxies:[{host,port,protocol,username,inUse,instanceName,connectionStatus,ownerJid}], outsidePool:[...] }`
(senhas nunca retornam). `outsidePool` = instâncias usando proxy que não está mais no pool.
Por instância: `GET /proxy/find/{instance}`.

## Armadilhas já vistas
- Residencial por GB (NodeMaven/Proxy-Seller "Residential") **não é ilimitado** — não usar para WhatsApp.
- "No rotating" em residencial: IP nunca troca, mas se o aparelho cair o proxy morre de vez.
- Anúncio "ISP" não garante ASN residencial — **sempre testar** (caso Proxy-Seller/M247).
- API oficial da Meta (canal `meta` do Evolution) elimina proxy e ban, mas cobra por conversa.
