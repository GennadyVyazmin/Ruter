# Ruter

Ruter — менеджер универсального VPN-шлюза на базе sing-box для Debian/Ubuntu.

Он позволяет:

- направлять через VPN одно устройство;
- направлять через VPN несколько устройств;
- направлять через VPN всю локальную сеть;
- временно отключать policy routing;
- использовать sing-box как прокси для других устройств и сервисов;
- выбирать VPN-сервер через MetaCubeXD.

После установки управление выполняется командой:

```bash
ruter
```

## Возможности

- установка и обновление sing-box;
- импорт VLESS REALITY-подписок;
- автоматический выбор VPN-сервера;
- ручное переключение серверов через MetaCubeXD;
- policy routing через отдельную таблицу;
- обход VPN для самой машины Ruter;
- маршрутизация одного, нескольких или всех устройств LAN;
- локальный mixed-proxy `127.0.0.1:2080`;
- LAN mixed-proxy `<IP Ruter>:2081`;
- диагностика `ruter doctor`;
- проверка конфигурации перед перезапуском;
- systemd-сервис `ruter-route.service`;
- обновление управляющего скрипта.

## Перед установкой

Ruter рекомендуется устанавливать на отдельную VM или физическую машину.

Для машины Ruter необходимо закрепить постоянный IP-адрес в настройках DHCP вашего роутера.

Например:

```text
192.168.1.50
```

Это важно, так как этот адрес используется устройствами локальной сети как адрес шлюза, прокси и веб-интерфейса MetaCubeXD.

## Быстрая установка

Для первоначальной установки нужны права `root`.

Если вы вошли под обычным пользователем:

```bash
su -
```

Введите пароль пользователя `root`.

Затем выполните весь блок целиком:

```bash
apt update && \
apt install -y sudo curl && \
curl -fsSL \
  'https://raw.githubusercontent.com/GennadyVyazmin/Ruter/refs/heads/main/install.sh' \
  -o /tmp/ruter-install.sh && \
chmod +x /tmp/ruter-install.sh && \
/tmp/ruter-install.sh
```

Скрипт автоматически установит остальные необходимые зависимости, sing-box и MetaCubeXD.

После установки:

```bash
ruter
```

## Маршрутизация

Во время установки можно выбрать режим:

```text
1) Одно устройство
2) Несколько устройств
3) Вся LAN-подсеть
4) Маршрутизацию отключить
```

Изменить режим позднее:

```bash
ruter route
```

## Прокси

Ruter автоматически создаёт два mixed-proxy.

Локальный:

```text
127.0.0.1:2080
```

Прокси для устройств и сервисов локальной сети:

```text
<IP Ruter>:2081
```

Например, при IP машины Ruter:

```text
192.168.1.50
```

адрес прокси будет:

```text
http://192.168.1.50:2081
```

Прокси использует тот же выбранный VPN-сервер, что и sing-box.

### Docker

Для контейнеров и приложений с поддержкой переменных окружения можно использовать:

```yaml
environment:
  - HTTP_PROXY=http://192.168.1.50:2081
  - HTTPS_PROXY=http://192.168.1.50:2081
```

Замените `192.168.1.50` на IP вашей машины Ruter.

## MetaCubeXD

MetaCubeXD устанавливается автоматически.

Веб-интерфейс доступен по адресу:

```text
http://<IP Ruter>:9090/ui
```

Например:

```text
http://192.168.1.50:9090/ui
```

Через MetaCubeXD можно:

- выбирать VPN-сервер вручную;
- использовать автоматический выбор `auto`;
- смотреть состояние серверов;
- проверять задержку.

Выбранный сервер используется как для policy routing, так и для LAN proxy на порту `2081`.

## Основные команды

```bash
ruter
ruter status
ruter doctor
ruter restart
ruter restart-singbox
ruter restart-route
ruter route
ruter sub
ruter rebuild
ruter update
ruter update-singbox
ruter update-ui
```

## Системные пути

```text
/etc/ruter/
/etc/sing-box/
/usr/local/lib/ruter/ruter.sh
/usr/local/bin/ruter
/usr/local/sbin/ruter-route.sh
/etc/systemd/system/ruter-route.service
```

## Порты

```text
2080    локальный mixed-proxy
2081    LAN mixed-proxy
9090    MetaCubeXD / Clash API
```

## Документация

- [Установка](docs/installation.md)
- [Маршрутизация](docs/routing.md)
- [Диагностика](docs/troubleshooting.md)
- [Переход со старой установки](docs/migration.md)

## Состояние проекта

Текущая версия — **Ruter 2.1.0**.

В этой версии добавлен LAN proxy на порту `2081`, который позволяет другим устройствам и сервисам локальной сети использовать VPN через Ruter без изменения их системного шлюза.

Существующие policy routing, локальный proxy и управление через MetaCubeXD продолжают работать независимо друг от друга.
