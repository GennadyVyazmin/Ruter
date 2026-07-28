# Переход со старой установки

Ruter использует собственные имена:

```text
/etc/ruter
/usr/local/sbin/ruter-route.sh
/etc/systemd/system/ruter-route.service
```

Перед первой установкой рекомендуется отключить прежний маршрутный сервис и удалить его unit-файл. Старую папку настроек сохраняй до успешной проверки новой установки.

После установки проверь:

```bash
sudo ruter status
sudo ruter doctor
```
