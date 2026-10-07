# Домашний сервер: контекст проекта

Неизменяемый домашний сервер на Fedora CoreOS. Конфигурация описана в этом репозитории в три уровня, приложения разворачиваются через GitOps (Flux) в однонодовый Kubernetes (KubeSolo).

Часть фактов ниже записана по памяти из обсуждения. Если что-то расходится с файлами в репозитории или с состоянием сервера, верить нужно репозиторию и серверу, а этот файл поправить.

## Архитектура: три уровня

| Уровень | Что | Где в репозитории | Когда применяется |
|---|---|---|---|
| 1. Система | Ignition (Butane): пользователи, ключи, аргументы ядра, сеть, базовые файлы | `sys_layer/` | Только при первой загрузке |
| 2. Сервисы ОС | Свой образ FCOS (Containerfile), на который делается `rpm-ostree rebase` | `service_layer/` | При обновлении образа + перезагрузка |
| 3. Приложения | Манифесты Kubernetes, синхронизирует Flux | `apps/` | `git push`, Flux применяет за несколько минут |

Правило разделения: всё, что меняется часто, живёт на уровне 3 и не требует пересборки образа или перезагрузки.

Версионирование образа по сообщению коммита: `[bump:major]`, `[bump:minor]`, без метки — patch.

## Хост

- ОС: Fedora CoreOS 44, поток stable. Работает как ВМ под libvirt/QEMU (диск `vda`).
- Имя: `homeserver.local`. Основной IP: `192.168.250.3` (`eth1`).
- `eth0`: зона firewalld `public`, `192.168.122.3/24`, шлюз в конфиге не задан (похоже на дефолтную NAT-сеть libvirt). Наружу из публичной зоны открыты только ssh, https, `51413/tcp+udp` (transmission) и `32400/tcp` (plex) — см. `service_layer/firewall/public.xml`.
- `eth1`: зона firewalld `trusted`, `192.168.250.3/24`, шлюз `192.168.250.1`. Это основная домашняя LAN; здесь же Pi-hole раздаёт DHCP (`192.168.250.100`–`192.168.250.110`, клиентам роутером объявляется `192.168.250.3`).
- Интерфейсы называются `eth0`, `eth1` (в аргументах ядра `net.ifnames=0 biosdevname=0`).
- Аргументы ядра: `mitigations=off`, `selinux=0`, `audit=0`. SELinux выключен, поэтому `:z`/`:Z` на томах ничего не делают.
- `systemd-resolved` выключен. `/etc/resolv.conf` — обычный файл (`overwrite: true` в Ignition), `search lan` + `nameserver 8.8.8.8`. NetworkManager не трогает его благодаря drop-in с `dns=none` и `rc-manager=unmanaged`.
- Firewalld включён. Зоны лежат в образе: `firewall/trusted.xml`, `firewall/public.xml`.

### Пользователи и группы

| Имя | UID/GID | Назначение |
|---|---|---|
| `core` | 1000/1000 | Основной пользователь, linger включён |
| `plex` | 1001, группа `plex` 1001 | Владелец файлов Plex |
| `audio` (хост) | GID 63 | Доступ к `/dev/snd` |
| `vault` (внутри образа Vault) | UID 100 | Владелец данных Vault |

### Диски

- Данные: LVM `/dev/mapper/vg_data-lv_data` → `/var/mnt/data`.
- Зеркало: LVM `/dev/mapper/vg_backup-lv_backup` → `/var/mnt/mirror`. Проверить, не осталось ли где-то старое имя `/var/mnt/data-mirror`.
- Монтируются systemd mount-юнитами (`var-mnt-data.mount`, `var-mnt-mirror.mount`) с `nofail,noatime,discard,errors=remount-ro`. Не через `storage.filesystems` в Ignition: LVM в initramfs FCOS не активируется, и загрузка падает.
- Владелец корня ФС на дисках выставлен один раз через `chown` на смонтированной ФС. Владелец папки-точки монтирования ни на что не влияет.
- В корне дисков лежат метки `.mirror-source` (данные) и `.mirror-target` (зеркало). Бэкап отказывается работать без них.
- Старые конфиги могут ссылаться на `/data/...`. На этом хосте такого пути нет, правильно `/var/mnt/data/...`.
- Данные приложений: `/var/mnt/data/ct_data/<приложение>/`.

## Уровень 1: Ignition

- Собирается из Butane (`variant: fcos`, `version: 1.7.0`).
- Секреты (`.auth.json` для ghcr.io, токены, ключи, `age.agekey`) подключаются через `local:` и **встраиваются в `config.ign`**.
- `age.agekey` (приватный ключ SOPS) кладётся в `/etc/homeserver/age.agekey` (0600); `flux-bootstrap.service` при каждой загрузке создаёт из него секрет `flux-system/sops-age`. На уже работающий сервер Ignition не применится, файл кладётся руками (см. README).
- **`config.ign` не должен лежать в git**: репозиторий публичный. Хранить только `.bu`, `config.ign` собирать локально. Файлы `config.ign` убраны из индекса и добавлены в `.gitignore`, но **в истории git остался старый `sys_layer/config.ign`** со встроенными `.auth.json` (токен ghcr.io) и `password_hash`. См. TODO ниже.
- Подводные камни Ignition на FCOS 44:
  - `primary_group` в пользователе требует, чтобы группа была объявлена в `passwd.groups`.
  - Ссылка `/etc/localtime` без `overwrite: true` падает, если файл уже есть в образе.
  - Регрессия SELinux-релейблинга при `home_dir` с симлинком (issue fedora-coreos-tracker #2216): `home_dir` не указывать или указывать `/var/home/...`.
- Отлаживать падения `ignition-files.service`: искать строку `CRITICAL` в `journalctl -u ignition-files`. Полный журнал удобнее всего снимать через serial-консоль или virtio-порт `com.coreos.ignition.journal`.

## Уровень 2: образ ОС

- База: `quay.io/fedora/fedora-coreos:stable`. Публикуется в `ghcr.io/fedextm/homeserver`.
- **Пакеты ставить через `dnf`, а не `rpm-ostree install`.** Образ stable отстаёт от репозитория `updates`, а `rpm-ostree` не обновляет базовые пакеты ради зависимостей и падает с `conflicting requests`.
- В Fedora 44 `nfs-utils-coreos` заменён на `nfs-client-utils`. Полный `nfs-utils` ставится поверх без конфликтов, swap не нужен.
- Слабые зависимости отключены: `--setopt=install_weak_deps=False`.
- `ostree container commit` нужен в конце `RUN`, где ставятся пакеты. В `RUN` с одним `systemctl enable` не нужен.
- `systemctl enable` для системных юнитов — без `--global` (он для пользовательских юнитов).
- Бинарники класть в `/usr/bin`, **не в `/usr/local/bin`**: в FCOS `/usr/local` — это симлинк на `/var/usrlocal`, и он не обновляется вместе с образом.
- Секреты в образ не класть никогда: образ уходит в реестр. Секреты доставляются через Ignition.
- В образе: samba, nfs-utils, cockpit (+ плагины cockpit-networkmanager, cockpit-system, cockpit-storaged — **cockpit-podman не ставится**), firewalld, fail2ban, flatpak, zsh, vim, wget, rclone, s3fs-fuse, alsa-utils, alsa-firmware и alsa-sof-firmware, htop/mc/atop/btop, KubeSolo, kubectl, flux CLI, манифесты Flux. Включены сервисы `smb`, `nfs-server`, `cockpit.socket`, `var-mnt-s3.mount`, `firewalld`, `fail2ban` (+ `kubesolo`, `flux-bootstrap`).

### Тестирование на работающей машине

`/usr` только для чтения. Варианты:
- `sudo rpm-ostree usroverlay` — временный слой для записи, исчезает после перезагрузки.
- Ставить в `/usr/local/bin` и `/etc/systemd/system`. **Перед переходом на образ обязательно удалить**: `/usr/local/bin` стоит в `PATH` раньше `/usr/bin`, а юниты в `/etc` перекрывают юниты из `/usr/lib`.

## Уровень 3: KubeSolo + Flux

### KubeSolo

- Версия v1.2.1 (в образе, `ARG KUBESOLO_VERSION`). Версию Kubernetes сверять на живой ноде: `kubectl get node`. Раньше при v1.2.0 это был 1.35.7. Однонодовый Kubernetes в одном процессе, своя встроенная containerd.
- Настройка через файл `/etc/kubesolo/config.yaml` (в репозитории `service_layer/k8s/kubesolo-config.yaml`, кладётся в образ с правами 600). Юнит запускает `kubesolo --config=/etc/kubesolo/config.yaml`. Что задано: `kubernetes.apiServer.extraSANs` (`192.168.250.3`, `homeserver.local`), `network.nodeIP`, `storage.localPath.enabled`, `storage.dbWALRepair`. Остальное по умолчанию. Проверка: `kubesolo --config=<файл> --print-config`.
  Переменные окружения `KUBESOLO_*` и флаги **перекрывают** файл, поэтому в `kubesolo.service` их не задавать. Применяется только при перезапуске.
  В юните остаются `KillMode=process`, `Delegate=yes`, `LimitRTPRIO=70`, `LimitMEMLOCK=infinity` (лимиты наследуются контейнерами, нужны MPD) и `After=var-mnt-data.mount`.
- Kubeconfig: `/var/lib/kubesolo/pki/admin/admin.kubeconfig`.
- Подов в `kube-system` мало (CoreDNS и `local-path-provisioner`): API-сервер, контроллеры и kubelet работают внутри процесса `kubesolo`. Это нормально.
- Сеть подов: мост `cni0`, поды `10.42.0.0/16` (проверить через `kubectl get node -o jsonpath='{.items[0].spec.podCIDR}'`), сервисы `10.43.0.0/16`, CoreDNS `10.43.0.10`.
- Встроенный балансировщик: у Service типа `LoadBalancer` `EXTERNAL-IP` равен IP ноды.

#### Firewalld для подов

Без этого у подов нет DNS и выхода в интернет. В образе это уже зашито в `service_layer/firewall/trusted.xml` (интерфейс `cni0` + источники `10.42.0.0/16` и `10.43.0.0/16`, зона `trusted` с `target="ACCEPT"`). На живой машине, которая ещё не перешла на обновлённый образ, правила накатываются вручную:
```bash
firewall-cmd --permanent --zone=trusted --add-interface=cni0
firewall-cmd --permanent --zone=trusted --add-source=10.42.0.0/16
firewall-cmd --permanent --zone=trusted --add-source=10.43.0.0/16
```

#### Исправленный баг KubeSolo v1.2.0 (#199)

В v1.2.0 функция `cleanStaleState` при каждом старте удаляла `/var/lib/kubesolo/containerd` целиком: образы скачивались заново после перезагрузки, а `systemctl restart kubesolo` создавал дубли всех подов (два процесса на одних данных: SQLite Plex, Transmission, Vault). Исправлено в v1.2.1 (вышел 29.09.2026). Пока образ на v1.2.0, **сервис `kubesolo` не перезапускать, только перезагружать машину целиком**. После перехода на образ с v1.2.1 перезапуск допустим, но на живом сервере сначала проверить `kubectl get pods -A` на дубли.

### Flux

- Установлен из `install.yaml` (не через `flux bootstrap`). Сервис `flux-bootstrap.service` при **каждой** загрузке применяет `install.yaml` и `flux-sync.yaml`. Это намеренно: так Flux обновляется вместе с образом. Ручные правки `GitRepository`/`Kustomization` через `kubectl` после перезагрузки перезапишутся, менять нужно `flux-sync.yaml`.
- Источник: `https://github.com/fedextm/homeserver-immutable`, ветка `main`. Репозиторий публичный, `secretRef` и секрет `git-auth` не нужны.
- `Kustomization` с именем `homeserver` смотрит в `./apps`, `prune: true`.
- `apps/kustomization.yaml` явно перечисляет подпапки приложений. Без него Flux возьмёт все YAML рекурсивно.
- Полезное: `flux get sources git -A`, `flux get kustomizations -A`, `flux reconcile kustomization homeserver --with-source`, `flux events -A`, `kubectl kustomize apps/` для локальной проверки.

### Приложения в `apps/`

Общие соглашения:
- Образы в `ghcr.io/fedextm/...` (containerd KubeSolo не видит `localhost/...` из Podman).
- Теги закреплены, без `latest`. Из-за бага KubeSolo `latest` фактически обновлялся бы при каждой перезагрузке.
- `strategy: Recreate` у всех: один экземпляр, данные на `hostPath`.
- `hostPath` с `type: Directory`: под не стартует, если диск не смонтирован, и не пишет на системный диск.
- Healthcheck: `tcpSocket` или `httpGet` на служебный адрес, без `curl` внутри образа.
- Логи в stdout, без `json-file`.
- Секреты в git в открытом виде не класть. Секреты хранятся зашифрованными через SOPS + age: файлы `apps/<app>/secret.enc.yaml`, правила в `.sops.yaml` (шифруются только `data`/`stringData`). Flux расшифровывает их ключом из секрета `flux-system/sops-age` (блок `decryption` в `flux-sync.yaml`). Приватный ключ вне git: `~/.config/sops/age/keys.txt` на рабочей станции (держать резервную копию) и `sys_layer/age.agekey` (в `.gitignore`). Как добавить секрет — см. README. Пока зашифрован только `pihole-web`; остальные секреты, если есть, создавались вручную через `kubectl create secret`.

| Приложение | Образ | Сеть | Особенности |
|---|---|---|---|
| `mpd` | `ghcr.io/fedextm/mpd:v0.24.15` | Service LoadBalancer 6600, 8000 | `privileged` + `hostPath /dev/snd`, `supplementalGroups: [63]`, UID/GID 1000, вывод на `hw:` для bit-perfect |
| `plex` | `docker.io/plexinc/pms-docker:1.43.4.10903-e5521bd8c` | `hostNetwork` | `privileged` + `/dev/dri`, `PLEX_UID=1001`, `PLEX_GID=1001`, транскодинг в `emptyDir` (`sizeLimit: 8Gi`), проба `/identity` |
| `transmission` | `ghcr.io/fedextm/transmission:v4.1.2` | `hostNetwork` | UID/GID 1000, без привилегий, `drop: ALL`, `terminationGracePeriodSeconds: 60` |
| `pihole` | `docker.io/pihole/pihole:2026.04.1` | `hostNetwork`, `dnsPolicy: Default` | DNS + DHCP, `NET_ADMIN`, `SYS_TIME`, `SYS_NICE`; пароль из секрета `pihole-web` |
| `backup` | `docker.io/library/alpine:3.24` | — | CronJob 03:30 Europe/Warsaw, `rsync` ставится в самом job'е (`apk add --no-cache rsync` при каждом запуске, не запечён в образ), см. ниже |

`vault` (`docker.io/hashicorp/vault:2.1.1`, Service LoadBalancer, данные в `hostPath /var/mnt/data/ct_data/vault/data`, `api_addr = http://192.168.250.3:8200`) есть в `apps/vault/` и в `apps/kustomization.yaml`. Решение Kubernetes vs Podman Quadlet формально не закрыто, см. «Архитектурные оговорки».

#### Бэкап `/var/mnt/data` → `/var/mnt/mirror`

- CronJob `data-mirror` в namespace `backup`, `concurrencyPolicy: Forbid`.
- Работает от root, чтобы на зеркале совпадали владельцы и права: `rsync -aHAX --numeric-ids --delete`. Без `drop: ALL` (нужны `CHOWN`, `FOWNER`, `FSETID`, `DAC_OVERRIDE`).
- Исключения: `lost+found`, `plex_backup`, `plexmediaserver`, `films`, `downloads`.
- Перед запуском проверяет метки `.mirror-source` и `.mirror-target`. Без этого `--delete` при несмонтированном источнике стёр бы зеркало.
- Код 24 (файлы исчезли во время копирования) считается успехом.
- Ручной запуск: `kubectl -n backup create job --from=cronjob/data-mirror data-mirror-test`.

### Архитектурные оговорки

- **Pi-hole и Vault лучше держать на Podman Quadlet, а не в Kubernetes.** Pi-hole раздаёт DNS и DHCP всей сети, а KubeSolo после перезагрузки поднимается минутами, пока сеть сидит без DNS. Vault не должен зависеть от кластера, которому выдаёт секреты. Манифест Pi-hole в Kubernetes сделан по просьбе владельца; манифест Vault для Kubernetes в репозитории уже есть и работает, но решение, остаётся ли он в Kubernetes или уходит в Quadlet, ещё не принято.
- KubeSolo официально не рекомендует соседство с другими контейнерными движками, а в FCOS встроен Podman. Пока конфликтов не замечено.
- После каждого перезапуска пода Vault запечатан — `kubectl -n vault exec -it deploy/vault -- vault operator unseal` (по порогу ключей).
- В libvirt-сети, где живёт ВМ, может работать встроенный dnsmasq с DHCP. Он конфликтует с Pi-hole: убрать блок `<dhcp>` через `virsh net-edit` на хосте или перевести ВМ на мост к физической сети.

## Образы, которые собираются из этого репозитория

**Проверено:** Containerfile для MPD и Transmission в этом репозитории сейчас нет — ни на `main`, ни на других ветках, ни в истории git. Единственный Containerfile в репозитории — `service_layer/Containerfile` (базовый образ ОС). Описание ниже, видимо, относится к сборке, которая живёт в другом месте (отдельный репозиторий или локальные неотслеживаемые скрипты) — стоит уточнить у владельца и поправить этот раздел, когда найдётся актуальный источник.

- **MPD:** многоэтапная сборка на `debian:trixie-slim`. Исходники качаются с musicpd.org по `ARG MPD_VERSION`. Runtime-зависимости вычисляются через `ldd` + `dpkg -S`. Отключены pulse, jack, pipewire, openal, sndio, ao, zeroconf, systemd, тесты. В итоговом образе `USER 1000:1000`.
- **Transmission:** `alpine:${ALPINE_VERSION}` + `transmission-daemon` + `tini`, `USER 1000:1000`, `ENTRYPOINT ["/sbin/tini", "--", ...]`, обязательно `--foreground`. Версию Transmission определяет версия Alpine, тег образа ставить по `transmission-daemon --version`. `settings.json` править только при остановленном контейнере.

## Незавершённое и планы

- [x] ~~Обновить KubeSolo до релиза с исправлением #199~~ — в образе v1.2.1. Осталось применить образ на сервере (`rpm-ostree rebase`) и убедиться, что перезапуск больше не плодит дубли.
- [x] ~~Перенести правила firewalld для `cni0` и сетей подов в `firewall/trusted.xml`~~ — уже сделано, см. `service_layer/firewall/trusted.xml`.
- [x] ~~Убрать `config.ign` из git~~ — убран из индекса, добавлен в `.gitignore`.
- [ ] Перевыпустить токен ghcr.io из `.auth.json` (остался в истории git; `password_hash` не критичен — вход по паролю закрыт, SSH только по ключам). Решить, чистить ли историю (`git filter-repo` + force-push).
- [ ] Положить `age.agekey` на работающий сервер в `/etc/homeserver/age.agekey` до rebase на образ с новым `flux-bootstrap.service`, иначе юнит не дойдёт до `flux-sync.yaml`. Сделать резервную копию ключа age.
- [ ] Секреты через Vault + External Secrets Operator: план есть (три Flux Kustomization `infra-controllers` → `infra-configs` → `homeserver` с `dependsOn`, ESO через HelmRelease, `ClusterSecretStore` с auth `kubernetes` к Vault на `192.168.250.3:8200`). Отложено.
- [x] ~~Секреты в git через SOPS + age~~ — настроено (Pi-hole). Перенести остальные секреты, если они есть.
- [ ] Vault: подумать о TLS и auto-unseal (версия образа закреплена, `api_addr` задан).
- [ ] Сборку образов (особенно MPD) перенести в GitHub Actions. В `sys_layer/actions-runner.service` уже лежит юнит self-hosted runner'а, но он не подключён через `sys_layer/config.yml` (Butane) — пока не включается при первой загрузке. Также непонятно, где сейчас фактически собираются образы MPD/Transmission — Containerfile для них в этом репозитории не найден (см. раздел выше).
- [ ] Renovate для обновления тегов образов и Helm-чартов.
- [ ] Restic для версионированных бэкапов конфигов и баз (в дополнение к rsync-зеркалу).
- [ ] В истории git (ветка `CI_versioning_pipeline`) когда-то лежал каталог `transmission/config/` с реальными данными Transmission (торренты, resume-файлы, settings.json) — стоит решить, нужно ли вычищать историю.

## Стиль работы с владельцем

- Общение на русском.
- Владелец сначала тестирует команды на живой машине, потом переносит в образ. Давать оба варианта путей, когда это важно.
- Перед советами про версии и текущее состояние проектов (FCOS, KubeSolo, Flux) проверять актуальную информацию: многое меняется быстро.
