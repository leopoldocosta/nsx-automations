# Runbook — Rolling Reboot diário (1 manager/dia) (PT-BR)

Operação do rolling reboot multi-DC: plano ordenado, cron diário na
orquestradora e rotina de acompanhamento.

> **Pré-requisito:** a plataforma multi-DC instalada e validada — todos os
> DCs com `exit_code=0` no fan-out. Veja
> [RUNBOOK_INSTALACAO.md](RUNBOOK_INSTALACAO.md) (Fases 0–2 e 5).
>
> **⚠ Gate de produção:** antes de instalar o cron, conclua o item 2 do
> [TODO.md](../TODO.md) (blindar o `reboot` contra confirmação interativa
> do nsxcli) e valide com um reboot controlado de 1 manager no DC piloto.
> `--dry-run` NÃO exercita o verbo `reboot` real.

## Como funciona

- `reboot_plan.conf` (orquestradora, git-ignorado): lista ordenada
  `<DC-LABEL> <manager-ip>` — 1 linha = 1 manager = 1 dia.
- Cron diário (02:00) chama `bin/rolling_reboot_next.sh`, que reboota **um**
  manager (o próximo do plano) via fan-out `--only-dc <DC> -- --only <ip>`.
- Sucesso → índice avança. Falha → índice **não** avança; o cron tenta o
  mesmo manager na noite seguinte. Nada é pulado em silêncio.
- Plano completo → cron vira no-op até o operador re-armar.

## Instalação (somente na orquestradora)

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
> não existirem — a ordem importa.

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

## Operação diária

```bash
./bin/rolling_reboot_next.sh --show-state            # o que rodou ontem, quem é o próximo
tail -50 logs/orchestrator_cron.log                  # saída do cron
ls aggregated_logs/ | tail -3                        # logs puxados por execução
./bin/rolling_reboot_next.sh --advance               # pular manager rebootado fora do ciclo
```

**Comportamento em falha:** se uma noite falhar (rede, cluster não-STABLE),
**o índice não avança** — o cron tenta o **mesmo** manager na noite seguinte.
Nada é pulado silenciosamente; com `NSX_NOTIFY_WEBHOOK` configurado, cada
`log_err` chega no canal.

## Solução de problemas

| Sintoma | Causa provável | Ação |
|---|---|---|
| Cron rodou mas nada aconteceu | plano completo | `--show-state`; re-arme com `--reset --yes` |
| Mesmo manager 2 noites seguidas | falha na 1ª noite (por design) | veja `logs/orchestrator_cron.log` + `aggregated_logs/` da noite anterior |
| `[LOCKED]` no jump | execução anterior ainda ativa | confira `/tmp/nsx_rolling_reboot.lock` no jump |
| Reboot travado em "waiting for STABLE" | cluster não reconciliou | no manager: `get cluster status`; investigue antes de qualquer bypass |
| Preciso pular um manager | rebootado fora do ciclo | `./bin/rolling_reboot_next.sh --advance` |
