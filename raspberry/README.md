# Home services na Raspberry Pi

Stos uruchamia Pi-hole z DHCP, Tailscale, Jellyfin oraz monitoring Grafana/Prometheus. `systemd-networkd` utrzymuje jedno stale IP uslugowe i automatycznie przenosi je miedzy Ethernetem a Wi-Fi. Ethernet jest preferowany, a Wi-Fi przejmuje adres po utracie kabla.

## Instalacja

Pierwsza instalacja wymaga tylko lokalnego pliku `.env` z hasłami. Plik jest ignorowany przez Git, więc kolejne aktualizacje go nie nadpisują.
Wersje obrazów są przypięte bezpośrednio w wersjonowanym `compose.yaml`, dlatego aktualizacja nie wymaga synchronizowania ich z lokalnym `.env`.

```bash
cd raspberry
cp .env.example .env
chmod 600 .env
nano .env
bash ./validate-config.sh .env
bash ./setup-home-services.sh
```

Pierwsze pobieranie obrazów pokazuje postęp w terminalu i nie ma krótkiego limitu czasu; na wolniejszym łączu może potrwać kilkanaście minut.

Ustaw dwa rozne dlugie hasla i opcjonalny klucz Tailscale. Interfejsy `eth0` i `wlan0` sa wykrywane automatycznie; ich nazwy zmieniaj tylko na nietypowym sprzecie. Hasla zawierajace znaki specjalne zapisz w pojedynczych cudzyslowach. Po udanym logowaniu instalator automatycznie wyczyści klucz Tailscale z `.env`. Dla pierwszego logowania bez klucza wykonaj po starcie:

```bash
docker exec -it tailscale tailscale up --accept-dns=false --hostname=raspberry-home
```

Po potwierdzeniu działania Pi-hole wyłącz DHCP w Funboxie i odnów dzierżawy klientów. W jednej podsieci powinien działać tylko jeden serwer DHCP.

## Aktualizacja istniejącej instalacji

Nie edytuj ręcznie plików w `/etc/systemd/network` ani ustawień interfejsu w `.env`. Instalator sam usuwa starszą konfigurację zarządzaną przez ten projekt, wykrywa `eth0` i `wlan0`, zachowuje bieżące połączenie podczas instalacji i po restarcie preferuje Ethernet z automatycznym powrotem na Wi-Fi.

```bash
cd ~/homeapi
git pull
cd raspberry
bash ./setup-home-services.sh
sudo reboot
```

Stary wpis `INTERFACE=eth0` w istniejącym `.env` jest ignorowany i nie trzeba go usuwać.

## Administracja

Zainstalowany kontroler znajduje się w katalogu wskazanym przez `BASE_DIR` (domyślnie `~/home-services`):

```bash
sudo ~/home-services/home-services.sh status
sudo ~/home-services/home-services.sh diagnose
sudo ~/home-services/home-services.sh update
sudo ~/home-services/home-services.sh stop
sudo ~/home-services/home-services.sh uninstall
sudo ~/home-services/home-services.sh purge
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
