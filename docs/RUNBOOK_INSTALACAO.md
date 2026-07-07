# Runbook de instalação — Plataforma multi-DC (PT-BR)

Guia passo a passo para instalar a PLATAFORMA em **1 VM orquestradora +
N VMs jump** (uma por datacenter): usuário de serviço, malha SSH, deploy,
inventários e chaves NSX. Esta base serve a **todas** as automações
(device_command, rolling reboot, KB404700, ...).

- Referência técnica completa (em inglês): [MULTIDC.md](MULTIDC.md)
- Operação do rolling reboot (plano + cron + rotina):
  [RUNBOOK_ROLLING_REBOOT.md](RUNBOOK_ROLLING_REBOOT.md)

> **Nota de arquitetura:** a VM orquestradora **também é o jump do DC dela** —
> ela entra no `datacenters.conf` como um DC normal e abre SSH para si mesma
> no fan-out. Ou seja: a Fase 1 é executada em **todas** as VMs (incluindo a
> orquestradora); a Fase 2 em diante, **somente** na orquestradora.

---

## Fase 0 — Pré-requisitos de rede

| Fluxo | Porta | Obrigatório |
|---|---|---|
| Orquestradora → cada VM jump (incluindo ela mesma) | TCP/22 | sim |
| Cada VM jump → managers NSX **do próprio DC** | TCP/22 | sim |
| Jump → internet/proxy (webhook Slack/Teams) | HTTPS | opcional |

Em todas as VMs: Bash ≥ 4.3, `ssh`, `rsync`, `git` (e `sshpass` apenas para o
registro inicial da chave). Use o **mesmo usuário** em todas (ex.: `netops`) —
simplifica o `datacenters.conf`.

---

## Fase 0.5 — Usuário de serviço `netops` (1x por VM; única etapa com root)

Todo o toolkit roda como um usuário Linux **comum e sem sudo** — se a
orquestradora for comprometida, o invasor ganha um shell limitado nos jumps,
não root em todos os datacenters. Em **cada** VM (incluindo a orquestradora):

```bash
useradd -m -s /bin/bash netops
passwd netops        # senha ÚNICA deste site (cofre); usada só no bootstrap do ssh-copy-id
```

Regras:
- `netops` fica **fora** de sudoers/wheel;
- uma senha diferente por site; após o `ssh-copy-id` o acesso é 100% por chave;
- clone, inventário, chaves NSX e cron: tudo pertence ao `netops`
  (`/home/netops/nsx-automations`), nunca ao root;
- endurecimento opcional no `sshd_config` do jump:
  `AllowUsers netops@<ip-da-orquestradora>`.

> Se as chaves NSX de um pilotos anterior foram registradas pelo root, use uma
> label própria ao registrar as do netops (ex.:
> `./bin/configure_ssh_keys.sh --type manager --label netops-key`) — labels de
> chave são únicas no NSX. Remova as chaves antigas do root após validar.

---

## Fase 1 — Em TODAS as VMs jump (incluindo a orquestradora)

Cada VM conhece **somente os managers do próprio DC** — é esse o isolamento
do modelo: jump comprometido = blast radius de 1 DC.

```bash
# 1. Clone
git clone https://github.com/leopoldocosta/nsx-automations.git ~/nsx-automations
cd ~/nsx-automations

# 2. Inventário CENTRAL do DC local (compartilhado por todas as automações)
cp inventory/managers.conf.example inventory/managers.conf
vim inventory/managers.conf
cp inventory/edge_nodes.example inventory/edge_nodes.txt      # se o DC tiver edges
vim inventory/edge_nodes.txt
```

> O `inventory/` é o local único de consulta do parque daquele DC: managers e
> edges ficam ali e **todas** as automações (atuais e futuras) leem de lá.
> Um arquivo local dentro de `automations/<nome>/` ainda tem precedência —
> é o override intencional para rodar contra um subconjunto.

DC com 1 cluster de gerenciamento (3 managers):

```ini
[GER1]
hosts = <mgr1-ip>, <mgr2-ip>, <mgr3-ip>
admin_user = admin
```

DC com 2 clusters (ex.: infrabase + workload domain) — a topologia do DC é
declarada **aqui**, no jump dele, não no plano do orquestrador:

```ini
[INFRA]
hosts = 10.7.0.10, 10.7.0.11, 10.7.0.12
admin_user = admin

[WLD]
hosts = 10.7.1.10, 10.7.1.11, 10.7.1.12
admin_user = admin
```

```bash
# 3. Registrar a chave SSH desta VM nos managers do DC local
#    (pede a senha admin UMA vez; depois nunca mais)
#    --hosts é opcional: o default é o inventory/ central
#    A chave entra com a label padrão "nsx-automation-key" — use
#    --label <outro-nome> APENAS se essa label já estiver ocupada no
#    device por uma chave antiga (o registro avisa "already exists" e
#    a verificação falha; labels são únicas por device).
./bin/configure_ssh_keys.sh --type manager

# 4. Validação: o próprio passo 3 já imprime "VERIFIED (BatchMode login ok)"
#    por device — esse é o critério de pronto. Conferência manual (opcional):
ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
    admin@<mgr1-ip> "get cluster status" | head -5
#    (o accept-new evita o "Host key verification failed" da 1ª conexão —
#     os scripts do toolkit já tratam isso sozinhos; só o ssh manual pede)

# 5. Opcional: webhook de erro + retenção de logs
echo 'export NSX_NOTIFY_WEBHOOK=https://hooks...' >> ~/.bashrc
echo 'export NSX_LOG_RETENTION_DAYS=60' >> ~/.bashrc
```

> A chave NSX registrada aqui **nunca sai desta VM**.

---

## Fase 2 — Somente na VM orquestradora

```bash
cd ~/nsx-automations

# 1. Chave DEDICADA orquestrador→jump (NÃO reutilize a chave do NSX)
ssh-keygen -t ed25519 -f ~/.ssh/orchestrator -N ""

# 2. Distribuir a pública para todas as VMs jump (incluindo ela mesma)
for jump in jump-dc1 jump-dc2 jump-dc3 jump-dc4 jump-dc5 jump-dc6 jump-dc7; do
  ssh-copy-id -i ~/.ssh/orchestrator.pub netops@$jump
done
# Se a orquestradora É o jump do DC dela:
#   cat ~/.ssh/orchestrator.pub >> ~/.ssh/authorized_keys

# 3. Inventário dos datacenters
cp datacenters.conf.example datacenters.conf
vim datacenters.conf
```

```ini
[DC-1]
jump_host = <ip-ou-fqdn-jump-dc1>
jump_user = netops
repo_path = /home/netops/nsx-automations

# ... [DC-2] a [DC-6] iguais ...

[DC-7]
jump_host = <ip-jump-dc7>
jump_user = netops
repo_path = /home/netops/nsx-automations
```

> O DC da própria orquestradora entra aqui também, apontando para ela mesma.

```bash
# 4. Testar conectividade + sincronizar código em todos os jumps
./bin/deploy.sh --all-dcs --conf ./datacenters.conf --dry-run   # confere o plano
./bin/deploy.sh --all-dcs --conf ./datacenters.conf             # executa

# 5. Smoke-test fim-a-fim SEM reboot: dry-run em todos os DCs
./bin/run_across_datacenters.sh \
   --conf ./datacenters.conf \
   --automation manager_rolling_reboot/nsx_rolling_reboot.sh \
   -- --dry-run
```

**Checkpoint:** confira `aggregated_logs/<ts>/summary.csv` — todas as linhas
devem ter `exit_code=0`. Se algum DC falhar aqui, o problema é SSH, chave ou
`repo_path` — resolva antes de seguir para a Fase 3.

---

## Fase 3 — Ativar automações

Com a plataforma validada (checkpoint da Fase 2 verde em todos os DCs):

- **Rolling reboot diário (1 manager/dia):**
  [RUNBOOK_ROLLING_REBOOT.md](RUNBOOK_ROLLING_REBOOT.md) — plano ordenado,
  cron na orquestradora, rotina diária e troubleshooting próprio.
- **Consultas na frota inteira:** `automations/device_command/`
  (ex.: `-- --cmd "get uptime"` via fan-out).
- Demais automações: README de cada pasta em `automations/`.

Manutenção contínua da plataforma:

```bash
# na orquestradora, após qualquer git pull:
./bin/deploy.sh --all-dcs --conf ./datacenters.conf   # re-sincroniza a frota
```

---

## Fase 5 — Onboarding de um NOVO datacenter (checklist por DC)

Com o piloto validado, cada DC novo segue este roteiro (~15 min por DC,
sem tocar nos DCs já ativos). Validado em campo no piloto de 2 DCs.

```bash
# ── A. Pré-requisitos (pedir com antecedência, idealmente em lote) ─────────
#  - firewall: <ip-orquestradora> → <ip-jump-novo> TCP/22
#  - firewall: <ip-jump-novo> → managers/edges DO DC dele TCP/22
#  - VM com bash 4.3+, rsync e sshpass instalados

# ── B. Na VM nova, como root (ÚNICA etapa com root; 1 minuto) ──────────────
useradd -m -s /bin/bash netops
passwd netops                    # senha única DESTE site (cofre)
dnf install -y rsync sshpass     # se a imagem não trouxe

# ── C. Na ORQUESTRADORA, como netops ───────────────────────────────────────
ssh-copy-id -i ~/.ssh/orchestrator.pub netops@<ip-jump-novo>   # senha 1x
vim datacenters.conf             # +1 seção [DC-X] (jump_host/jump_user/repo_path)
./bin/run_command_across_dcs.sh --only-dc DC-X -- hostname     # malha ok?
./bin/deploy.sh --all-dcs --conf ./datacenters.conf            # código chega lá
#   (o deploy cria o diretório e copia tudo — o jump NÃO precisa de git clone)

# ── D. No jump novo, como netops (via malha) ───────────────────────────────
ssh -i ~/.ssh/orchestrator netops@<ip-jump-novo>
cd ~/nsx-automations
cp inventory/managers.conf.example inventory/managers.conf && vim inventory/managers.conf
cp inventory/edge_nodes.example inventory/edge_nodes.txt   && vim inventory/edge_nodes.txt
./bin/configure_ssh_keys.sh --type manager    # exigir VERIFIED (label padrão)
./bin/configure_ssh_keys.sh --type edge       # exigir VERIFIED
#   (--label <nome> só se a label padrão já existir no device — ver Fase 1)
./automations/device_command/device_command.sh get uptime       # N/N EXIT 0
exit

# ── E. Na orquestradora: validação final do DC ─────────────────────────────
./bin/run_across_datacenters.sh --conf ./datacenters.conf --only-dc DC-X \
    --automation device_command/device_command.sh -- --cmd "get uptime"
cat aggregated_logs/<ts>/summary.csv        # exit_code=0 → DC onboarded
```

Critério de pronto por DC: **todos os registros de chave com `VERIFIED`** e o
fan-out `--only-dc` com `exit_code=0`. Sem VERIFIED = não avance (as builds
variam; o script diz exatamente o que investigar quando falha).

Lições do piloto já embutidas nos scripts — se aparecerem, são conhecidas:
- senha root divergente em edges → registro root falha claro; siga (TODO 7)
- label já existente de piloto antigo → `del user <u> ssh-keys label <l>` no
  device e re-execute

---

## Solução de problemas rápida

| Sintoma | Causa provável | Ação |
|---|---|---|
| `summary.csv` com `exit_code≠0` em um DC | SSH orquestrador→jump | `ssh -i ~/.ssh/orchestrator netops@<jump>` manual; confira `authorized_keys` |
| `No route to host` num DC novo | firewall sem regra orquestradora→jump TCP/22 | pedir liberação (Fase 5-A); `ping` + teste `/dev/tcp/<ip>/22` distinguem porta vs rota |
| `Permission denied` no jump→NSX | chave não registrada no manager | rode a Fase 1 passo 3 naquele jump |
| Registro de chave sem `VERIFIED` | build exige forma diferente / label antiga / senha errada | o próprio script imprime o caminho (del + rerun, ou checagem de algoritmo) |
| `Permissão negada` ao executar script | bit de execução ausente no clone | `git pull` (modos corrigidos no repo) ou `chmod +x <script>` |

Problemas específicos do rolling reboot: ver
[RUNBOOK_ROLLING_REBOOT.md](RUNBOOK_ROLLING_REBOOT.md#solução-de-problemas).
