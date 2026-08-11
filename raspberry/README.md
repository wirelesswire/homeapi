# Home services na Raspberry Pi

Stos uruchamia Pi-hole z DHCP, Tailscale, Jellyfin oraz monitoring Grafana/Prometheus. Konfiguracja sieci jest zarzadzana przez jeden aktywny menedzer (`NetworkManager` albo `dhcpcd`), a Compose startuje z systemd po uzyskaniu lacznosci.

## Instalacja

```bash
cd raspberry
cp .env.example .env
chmod 600 .env
nano .env
bash ./validate-config.sh .env
bash ./setup-home-services.sh
```

Ustaw co najmniej poprawny interfejs, dwa rozne dlugie hasla i opcjonalny klucz Tailscale. Hasla zawierajace znaki specjalne zapisz w pojedynczych cudzyslowach. Po udanym logowaniu instalator automatycznie wyczyści klucz Tailscale z `.env`. Dla pierwszego logowania bez klucza wykonaj po starcie:

```bash
docker exec -it tailscale tailscale up --accept-dns=false --hostname=raspberry-home
```

Po potwierdzeniu działania Pi-hole wyłącz DHCP w Funboxie i odnów dzierżawy klientów. W jednej podsieci powinien działać tylko jeden serwer DHCP.

## Administracja

Zainstalowany kontroler znajduje się domyślnie w `/home/pi/home-services/home-services.sh`:

```bash
sudo /home/pi/home-services/home-services.sh status
sudo /home/pi/home-services/home-services.sh diagnose
sudo /home/pi/home-services/home-services.sh update
sudo /home/pi/home-services/home-services.sh stop
sudo /home/pi/home-services/home-services.sh uninstall
sudo /home/pi/home-services/home-services.sh purge
```

`uninstall` usuwa usługi systemd i kontenery, ale zachowuje dane. `purge` wymaga wpisania `USUN-DANE` i usuwa katalog deploymentu; katalog mediów pozostaje nietknięty.

Grafana jest dostępna na `http://192.168.1.14:3000`. Prometheus i exportery nasłuchują wyłącznie na loopbackie hosta.

## Testy statyczne

```bash
bash -n ./*.sh monitoring/*.sh tests/*.sh
bash ./tests/test-config.sh
docker compose --env-file .env.example -f compose.yaml config --quiet
shellcheck ./*.sh monitoring/*.sh tests/*.sh
```
