# Ruter

Ruter — менеджер универсального VPN-шлюза на базе sing-box для Debian/Ubuntu.

Он позволяет направлять через VPN:

- одно устройство;
- несколько устройств;
- всю локальную сеть;
- либо временно отключать policy routing.

После установки управление выполняется одной командой:

```bash
sudo ruter
```

## Возможности

- установка и обновление sing-box;
- импорт VLESS REALITY-подписок;
- MetaCubeXD;
- маршрутизация через отдельную таблицу;
- обязательный обход VPN для самой VM;
- управление несколькими клиентами;
- диагностика `ruter doctor`;
- безопасная проверка конфигурации перед перезапуском;
- обновление управляющего скрипта;
- systemd-сервис `ruter-route.service`.

## Быстрая установка

```bash
curl -fsSL \
  'https://raw.githubusercontent.com/GennadyVyazmin/Ruter/refs/heads/main/install.sh' \
  -o /tmp/ruter-install.sh

chmod +x /tmp/ruter-install.sh
sudo /tmp/ruter-install.sh
```

После установки:

```bash
sudo ruter
```

## Основные команды

```bash
sudo ruter status
sudo ruter doctor
sudo ruter restart
sudo ruter restart-singbox
sudo ruter restart-route
sudo ruter route
sudo ruter sub
sudo ruter rebuild
sudo ruter update
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

## Документация

- [Установка](docs/installation.md)
- [Маршрутизация](docs/routing.md)
- [Диагностика](docs/troubleshooting.md)
- [Переход со старой установки](docs/migration.md)

## Состояние проекта

Текущая версия — первый полностью переименованный релиз Ruter. На следующем этапе большой управляющий скрипт будет разделён на самостоятельные модули без изменения пользовательских команд.
