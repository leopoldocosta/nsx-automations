# Session Handoff — nsx-automations

> Estado vivo entre sessões. `AGENTS.md` + `TODO.md` são a fonte de verdade do
> projeto; este doc é o "onde paramos". Atualize ou apague conforme resolver.
> Última atualização: **2026-09-04**.

## Foco atual: reautomatizar o rolling reboot

Migrar do rolling reboot **antigo** (script pré-toolkit `deploy_nsx_v14.sh`, em
cron por-DC nas **pontes antigas**) para o modelo **novo, já pronto no repo**:
cron central na orquestradora — `bin/rolling_reboot_next.sh` + `reboot_plan.conf`
+ estado `run/rolling_global_state`; **1 manager/dia** via fan-out. Objetivo do
dono: deixar os reboots **programados**, sem reiniciar nada fora de janela.

- Pontes **antigas**: o dono **desativa o cron antigo ele mesmo** — não mexer.
- Alvo: subir o modelo novo nas **pontes ativas**. Usuário de jump = **netops**
  (confirmado; "devops" foi lapso do dono).

## Bloqueador principal — gate TODO #2 (reboot real nunca validado)

O caminho de reboot real (`reboot_manager_and_wait`: `ssh_admin reboot <<<yes`,
espera TCP cair/voltar, gate `get cluster status` STABLE, e a trava **"ainda
online após MAX_WAIT → aborta, rc1"**) **nunca foi exercido contra um manager
real**. `NSX_DRY_RUN=1` **pula** esse caminho. Enquanto o gate não fecha,
`bin/install_orchestrator_cron.sh` não vai pra prod (o próprio runbook barra).

## Feito nesta sessão (2026-08-25)

- **Sim WSL criado e validado:** `automations/manager_rolling_reboot/sim_reboot_wsl.sh`.
  Sourceia as libs reais, dubla só `ssh_admin`/`tcp_check`, e **afirma** 4
  cenários (roda em segundos; exit≠0 se algo desviar):
  1. 1 manager: cai→volta→STABLE → rc0;
  2. cluster de 3 sequencial → rc0, state file limpo no fim;
  3. **trava de segurança**: reboot que não pegou → rc1 (não reporta falso sucesso);
  4. cluster não estabiliza → rc1.
  Usa IPs de documentação (192.0.2.x). Rodou **verde** no Git Bash da estação.
  Prova a **orquestração**, não o verbo real — o gate continua aberto.
- `README.md` da automação atualizado com a linha do sim (docs em lockstep).

## Pendências / próximos passos

1. **Rodar o sim na WSL real** (Ubuntu) — já rodou verde no Git Bash; a Ubuntu é
   o alvo. Caminho:
   `/mnt/c/Users/leopoldo.costa/OneDrive/Documents/GitHub/nsx-automations` ou clonar.
2. **Fechar o gate TODO #2:** 1 reboot real controlado de um manager (PoC),
   **assistido**, observando cai→volta→STABLE→índice avança.
   `test_reboot_single.sh <ip>` faz exatamente isso.
3. **Timing — REVISAR:** o alvo original era "começar dia 1º" via cron de mês
   `0 2 * 9 *`. **Hoje é 2026-09-04 — o dia 1º de setembro já passou** e nada foi
   instalado. Redecidir: campanha parcial de setembro, esperar outubro
   (`0 2 * 10 *`), ou trava `--not-before` no código.
4. **Plano + deploy (TODO #5-ish):** gerar/conferir `reboot_plan.conf`
   (`bin/generate_reboot_plan.sh` ou à mão; `--list`/`--dry-run`), depois
   `deploy.sh` nas pontes ativas.

## Decisões tomadas

- **Usuário de jump = netops** (não devops).
- **Data de início fica no cron**, não em código: `0 2 * 9 *` = todo dia de
  setembro 02:00 — começa sozinho no 1º, não reinicia antes, vira no-op quando o
  plano acaba. É **campanha de 1 mês**; pra recorrer todo mês → re-arme mensal
  (`--reset`) ou trava `--not-before`.
- **Intervalo entre managers:** 300s nos testes, 3600s (default) na janela de
  prod (`NSX_REBOOT_INTERVAL`).
- **Sim co-localizado** com `test_reboot_single.sh` (pasta da automação).

## Aprendizados / armadilhas

- `NSX_DRY_RUN=1` loga "would reboot" e sai 0 — **não** exercita reboot real.
  Dry-run ≠ gate.
- **Cron diário instalado hoje reinicia hoje à noite**, não no dia 1º. "Começar
  no dia 1º" com cron diário exige data no cron ou trava de data.
- A trava "ainda online → aborta, rc1" impede o índice diário de avançar por cima
  de um manager que não reiniciou. **Preservar.**
- Estação Windows é **só edição** (memória `project_nsx_automations`, 2026-08-03):
  não rodar automação contra NSX do laptop (rede corp + proxy + WSL). ⚠ **Conflita**
  com o que o dono disse nesta sessão ("alcanço as managers do meu computador") —
  ver pergunta aberta.

## Perguntas em aberto (resolver antes de agendar reboot real)

- **Por onde roda o teste real?**
  (a) **orquestradora/fan-out** — precisa do DC no `datacenters.conf` + as 3 IPs no
  `managers.conf` do jump;
  (b) **direto da estação/WSL** — precisa repo + chave `id_rsa` registrada como
  admin nas 3 managers + alcance.
  O dono disse alcançar do computador, mas a memória diz "laptop só edita".
- **DC de PoC:** 3 managers (IPs reais **só** no `managers.conf` do jump — fora do
  repo, nunca commitar). Rótulo do DC no `datacenters.conf` a definir.
- **Commit:** o dono ainda não decidiu (ver abaixo).

## Trabalho não commitado (nesta estação)

- **Rolling reboot:** `automations/manager_rolling_reboot/sim_reboot_wsl.sh` (novo)
  + linha no `README.md`.
- **routing_model_audit** (sessão anterior, ainda não commitado):
  `automations/routing_model_audit/{routing_model_audit.sh,README.md}` + entrada no
  `CHANGELOG.md`. Ferramenta **read-only** que audita se o boundary NSX↔underlay é
  BGP ou rota estática (por Tier-0, via Policy API GET). `bash -n` ok.
- **edge_fleet_csv** (mais antigo): `bin/edge_fleet_csv.sh` + rollup, pendente.
- Fluxo: editar no Windows → commit/push → `git pull` na orquestradora →
  `deploy.sh --all-dcs`.

## Fora do nsx-automations (registrado na memória, não aqui)

- **VS Code:** instalado + extensões (Python, Go, shellcheck, bash-ide,
  claude-code). Python 3.14 ok; **Go toolchain NÃO instalado** (extensão ociosa).
  Memórias `work_env_windows_dev_toolchain` / `user_dev_profile`.
- **GitNexus:** avaliado — baixo encaixe (não parseia Bash/shell); útil só em
  projeto de linguagem suportada. Memória `reference_gitnexus`.
