# 3proxy installer — SOCKS5 + HTTPS (HTTP CONNECT)

Установочный скрипт для поднятия личного прокси-сервера (SOCKS5 + HTTPS) на VPS под Ubuntu.

* 🚀 SOCKS5-прокси (по умолчанию порт `1080`)
* 🌐 HTTPS / HTTP CONNECT-прокси (по умолчанию порт `3128`)
* 🔒 Авторизация по логину и паролю
* ⚙️ Автозапуск через `systemd`
* 📜 Логи в `/var/log/3proxy/`
* 🧱 Автоматическая настройка firewall (`ufw`)
* 💾 Поддержка ограничения доступа по IP

---

## ⚙️ Быстрый старт (одной командой)

Запускать на чистом VPS (Ubuntu 22.04/24.04, от root):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/<YOUR_GH_USERNAME>/<YOUR_REPO>/main/install_3proxy_socks5_https.sh)
```

> 🔸 Замени `<YOUR_GH_USERNAME>` и `<YOUR_REPO>` на свои реальные значения.

Скрипт спросит:

* Версию 3proxy (по умолчанию `0.9.5`)
* Порт SOCKS5
* Порт HTTPS (HTTP CONNECT)
* Логин и пароль
  (в пароле **нельзя** использовать `:` — это разделитель)
* Один IP для доступа (или оставь пустым, чтобы открыть всем)

---

## 🔍 Проверка работы

**SOCKS5:**

```bash
curl -v --socks5-hostname 'USER:PASS'@<SERVER_IP>:1080 https://ifconfig.co
```

**HTTPS:**

```bash
curl -v -x http://USER:PASS@<SERVER_IP>:3128 https://ifconfig.co
```

Оба запроса должны вернуть IP твоего VPS.

---

## 📁 Полезные пути

| Назначение   | Путь                                 |
| ------------ | ------------------------------------ |
| Конфигурация | `/usr/local/3proxy/conf/3proxy.cfg`  |
| Логи         | `/var/log/3proxy/3proxy.log`         |
| Юнит systemd | `/etc/systemd/system/3proxy.service` |
| Бинарь       | `/usr/bin/3proxy`                    |

---

## ⚙️ Управление

```bash
sudo systemctl status 3proxy --no-pager
sudo systemctl restart 3proxy
sudo tail -f /var/log/3proxy/3proxy.log
```

---

## 💡 Советы по безопасности

* Ограничивай доступ по IP (если это личный прокси).
* Используй длинные пароли без `:`.
* Следи за логами:

  ```bash
  tail -f /var/log/3proxy/3proxy.log
  ```
* После настройки закрой SSH-доступ по паролю (оставь только ключи).

---

## 🔁 Обновление или изменение конфигурации

Чтобы поменять порты, логины или пароли —
отредактируй `/usr/local/3proxy/conf/3proxy.cfg` и перезапусти службу:

```bash
sudo systemctl restart 3proxy
```

---

## ❌ Удаление

```bash
sudo systemctl stop 3proxy
sudo systemctl disable 3proxy
sudo rm -f /etc/systemd/system/3proxy.service
sudo systemctl daemon-reload
sudo rm -rf /usr/local/3proxy /var/log/3proxy /usr/local/src/3proxy-build
sudo rm -f /usr/bin/3proxy /usr/local/bin/3proxy
```

(по желанию закрой порты)

```bash
sudo ufw delete allow 1080/tcp
sudo ufw delete allow 3128/tcp
```

---

## 🧩 Проверено

✅ Ubuntu 22.04 LTS
✅ Ubuntu 24.04 LTS
✅ Работает на чистом VPS (VDSina, Hetzner, Contabo, OVH, DigitalOcean и др.)

---

**Автор:** [@<YOUR_GH_USERNAME>](https://github.com/<YOUR_GH_USERNAME>)
Лицензия: MIT
