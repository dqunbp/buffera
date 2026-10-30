<p align="center">
  <a href="README.md">English</a> | <a href="README.ru.md"><strong>Русский</strong></a> | <a href="README.es.md">Español</a> | <a href="README.de.md">Deutsch</a> | <a href="README.fr.md">Français</a> | <a href="README.pt-BR.md">Português (Brasil)</a> | <a href="README.zh-Hans.md">简体中文</a> | <a href="README.ja.md">日本語</a>
</p>

<p align="center">
  <a href="https://buffera.app/ru/">
    <img src="landing/src/og/ru.png" alt="Buffera — хорошие буфера. Всё помнят. История буфера обмена для Mac." width="900">
  </a>
</p>

<p align="center">
  <strong>Текст, ссылки, картинки и файлы — под рукой, даже после следующего ⌘C.</strong><br>
  macOS 14+ · Apple Silicon · Русский, английский, испанский, немецкий, французский, португальский (Бразилия), упрощённый китайский и японский
</p>

<p align="center">
  <a href="https://github.com/dqunbp/buffera/releases/latest/download/Buffera-macOS-arm64.dmg"><strong>Скачать для Mac ↓</strong></a>
  &nbsp; · &nbsp;
  <a href="https://buffera.app/ru/">Сайт и демо</a>
  &nbsp; · &nbsp;
  <a href="https://buffera.app/ru/docs/">Руководство</a>
  &nbsp; · &nbsp;
  <a href="https://github.com/dqunbp/buffera/releases">Что нового</a>
</p>

## Скопировал. Нашёл. Вернул.

Buffera сохраняет историю буфера обмена на твоём Mac. Открой её через <kbd>⌘⌥V</kbd>, найди нужную запись и нажми <kbd>Enter</kbd> — она снова в буфере, готова к вставке через <kbd>⌘V</kbd>. Карточки можно и просто перетаскивать в другие приложения.

| Возможность | Для чего |
| :--- | :--- |
| **Поиск по истории** | Найти текст, ссылку или файл; отфильтровать по приложению и дате. |
| **Текст на картинках** | Найти скриншот по словам внутри него — распознавание работает на Mac. |
| **Поиск по смыслу и чат** | Спросить «какую ошибку я копировал вчера?» и вернуться к записи из ответа. |
| **Скопировать иначе** | Убрать форматирование, привести JSON в порядок или превратить текст в `.txt` / `.md`. |
| **Избранное и соседние записи** | Сохранить важное или посмотреть, что копировал до и после. |
| **MCP для агентов** | Подключить историю к Claude Code, Codex и другим MCP-клиентам. |

Светлая, тёмная и системная темы. Список или сетка карточек. Настраиваемые клавиши и закрепление окна поверх других приложений.

## Начать за минуту

1. [Скачай DMG](https://github.com/dqunbp/buffera/releases/latest/download/Buffera-macOS-arm64.dmg) и перетащи Buffera в **Программы**.
2. Открой приложение и пройди короткую настройку — необязательные шаги можно пропустить.
3. Скопируй что-нибудь и нажми <kbd>⌘⌥V</kbd>.

> Buffera 1.0.0 подписана Developer ID и нотарифицирована Apple. При первом запуске подтверди открытие скачанного приложения, если macOS попросит. [Подробности установки →](docs/INSTALL.txt)

Поиск по смыслу и чат включаются отдельно в настройках и скачивают локальные модели. Обычная история работает без них. [Настройка поиска и моделей →](https://buffera.app/ru/docs/search/)

## Твоя история — на твоём Mac

История, распознавание текста и встроенные модели работают локально. Доступ внешних агентов через MCP выключен по умолчанию; после подключения обработка прочитанного зависит от выбранного агента.

Помеченные приложением-источником секреты по умолчанию не сохраняются. Можно включить их зашифрованное хранение; содержимое скрытых записей недоступно поиску, чату и MCP. Пароль без такой отметки может сохраниться как обычный текст. [Как устроена приватность →](https://buffera.app/ru/docs/privacy/)

## Дальше

[Все клавиши и приёмы](https://buffera.app/ru/docs/shortcuts/) · [Подключить агента](https://buffera.app/ru/docs/agents/) · [Спросить Buffera](https://buffera.app/ru/docs/assistant/) · [Релизы](https://github.com/dqunbp/buffera/releases)

<details>
<summary><strong>Собрать из исходников</strong> — Swift + AppKit</summary>

Нужны Command Line Tools со **Swift 6.4+**. Полный Xcode не обязателен. Из корня репозитория:

```sh
zsh scripts/build-app.sh
open dist/Buffera.app
```

Доступные переводы собраны в [указателе технической документации](docs/README.ru.md):

[Подробности сборки](docs/guide.md#сборка-и-запуск) · [Проверки](docs/guide.md#проверка) · [Архитектура](docs/architecture.md) · [Локализация](docs/localization.md) · [Выпуск новой версии](docs/releases.md)

</details>

---

Нравится Buffera? [Поддержать разработку ↗](https://web.tribute.tg/d/SHI)
