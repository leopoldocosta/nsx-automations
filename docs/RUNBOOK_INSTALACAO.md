# Runbook de instalação — Rolling reboot multi-DC (PT-BR)

Guia passo a passo para instalar o toolkit em **1 VM orquestradora + N VMs jump**
(uma por datacenter) e ativar o rolling reboot diário de 1 manager/dia.

Referência técnica completa (em inglês): [MULTIDC.md](MULTIDC.md).

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
registro inicial da chave). Use o **mesmo usuário** em todas (ex.: `nsxops`) —
simplifica o `datacenters.conf`.

---

## Fase 1 — Em TODAS as VMs jump (incluindo a orquestradora)

Cada VM conhece **somente os managers do próprio DC** — é esse o isolamento
do modelo: jump comprometido = blast radius de 1 DC.

```bash
# 1. Clone
git clone https://github.com/leopoldocosta/nsx-automations.git ~/nsx-automations
cd ~/nsx-automations

# 2. Inventário do DC LOCAL apenas
cp automations/manager_rolling_reboot/managers.conf.example \
   automations/manager_rolling_reboot/managers.conf
vim automations/manager_rolling_reboot/managers.conf
```

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
./bin/configure_ssh_keys.sh --type manager \
   --hosts automations/manager_rolling_reboot/managers.conf

# 4. Validar que a chave pegou (não deve pedir senha)
ssh -o BatchMode=yes admin@<mgr1-ip> "get cluster status" | head -5

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
ssh-keygen -t ed25519 -f ~/.ssh/nsx_dc_fanout -N ""

# 2. Distribuir a pública para todas as VMs jump (incluindo ela mesma)
for jump in jump-dc1 jump-dc2 jump-dc3 jump-dc4 jump-dc5 jump-dc6 jump-dc7; do
  ssh-copy-id -i ~/.ssh/nsx_dc_fanout.pub nsxops@$jump
done
# Se a orquestradora É o jump do DC dela:
#   cat ~/.ssh/nsx_dc_fanout.pub >> ~/.ssh/authorized_keys

# 3. Inventário dos datacenters
cp datacenters.conf.example datacenters.conf
vim datacenters.conf
```

```ini
[DC-1]
jump_host = <ip-ou-fqdn-jump-dc1>
jump_user = nsxops
repo_path = /home/nsxops/nsx-automations

# ... [DC-2] a [DC-6] iguais ...

[DC-7]
jump_host = <ip-jump-dc7>
jump_user = nsxops
repo_path = /home/nsxops/nsx-automations
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

## Fase 3 — Plano de reboot + cron (somente na orquestradora)

```bash
# 1. Plano ordenado: 1 linha = 1 manager = 1 dia
cp examples/reboot_plan_7dc_24managers.example reboot_plan.conf
vim reboot_plan.conf     # troque os IPs de exemplo pelos reais

# 2. Conferir ordem e alvo do primeiro dia
./bin/rolling_reboot_next.sh --list       # [NEXT] deve ser o 1º manager do plano
./bin/rolling_reboot_next.sh --dry-run    # preview real via SSH; NÃO avança o índice

# 3. Instalar o cron diário (02:00; ajuste com CRON_HOUR/CRON_MINUTE)
./bin/install_orchestrator_cron.sh
crontab -l | grep rolling_reboot_next     # confirmar
```

> O installer se recusa a rodar se `datacenters.conf` ou `reboot_plan.conf`
> não existirem — a ordem das fases importa.

**Ordenação do plano (round-robin entre clusters):** o sample intercala os
clusters de forma que dois managers do **mesmo** cluster fiquem sempre N dias
distantes (N = nº de clusters). Nenhum cluster fica degradado em noites
consecutivas — defesa em profundidade além do gate `STABLE` + 24h do cron.

**Para começar no dia 01 do mês:** instale tudo antes e, na véspera, rode:

```bash
./bin/rolling_reboot_next.sh --reset --yes
```

Madrugada do dia 01 → 1º manager; ao fim do plano o cron vira no-op
("plan complete") até o próximo `--reset`. Todo mês, repita o `--reset`
no dia 01 (ou na véspera).

---

## Fase 4 — Operação diária

```bash
./bin/rolling_reboot_next.sh --show-state            # o que rodou ontem, quem é o próximo
tail -50 logs/orchestrator_cron.log                  # saída do cron
ls aggregated_logs/ | tail -3                        # logs puxados por execução
./bin/rolling_reboot_next.sh --advance               # pular manager rebootado fora do ciclo
./bin/deploy.sh --all-dcs --conf ./datacenters.conf  # re-sincronizar código após git pull
```

**Comportamento em falha:** se uma noite falhar (rede, cluster não-STABLE),
**o índice não avança** — o cron tenta o **mesmo** manager na noite seguinte.
Nada é pulado silenciosamente; com `NSX_NOTIFY_WEBHOOK` configurado, cada
`log_err` chega no canal.

---

## Solução de problemas rápida

| Sintoma | Causa provável | Ação |
|---|---|---|
| `summary.csv` com `exit_code≠0` em um DC | SSH orquestrador→jump | `ssh -i ~/.ssh/nsx_dc_fanout nsxops@<jump>` manual; confira `authorized_keys` |
| `Permission denied` no jump→NSX | chave não registrada no manager | rode a Fase 1 passo 3 naquele jump |
| Cron rodou mas nada aconteceu | plano completo | `--show-state`; re-arme com `--reset --yes` |
| Mesmo manager 2 noites seguidas | falha na 1ª noite (por design) | veja `logs/orchestrator_cron.log` + `aggregated_logs/` da noite anterior |
| `[LOCKED]` no jump | execução anterior ainda ativa | confira `/tmp/nsx_rolling_reboot.lock` no jump |
| Reboot travado em "waiting for STABLE" | cluster não reconciliou | no manager: `get cluster status`; investigue antes de qualquer bypass |
