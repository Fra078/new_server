# new_server

Configurazione del mio home server (Raspberry Pi 5 + NAS + Docker/Portainer + Tailscale).

- `*/docker-compose.yaml` — uno stack per cartella (Portainer git stack, tranne `core/` e `portainer/`)
- `host/` — configurazione del sistema (systemd, fstab, backup, SSH, Tailscale Serve), applicata da `host/install.sh`
- `scripts/` — avvio infrastruttura e deploy degli stack via API Portainer
- `.env.example` — variabili richieste

Documentazione completa, architettura e procedura di ricostruzione: **[CLAUDE.md](CLAUDE.md)**.
