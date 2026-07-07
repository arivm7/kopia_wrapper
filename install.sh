#!/usr/bin/env bash
# install.sh
# ------------------------------------------------------------------------------
# Устанавливает kopia_common.sh, kopia_backup.sh и kopia_restore_to.sh в
# выбранную папку и настраивает права на выполнение.
#
# Целевая папка задаётся:
#   - позиционным аргументом (любой произвольный путь), либо
#   - интерактивным выбором из трёх предустановленных вариантов, если
#     аргумент не передан.
# ------------------------------------------------------------------------------

set -uo pipefail



APP_TITLE="Установщик скриптов резервного копирования Kopia"
APP_NAME="$(basename "$0")"
APP_DIR="$(cd "$(dirname "$0")" && pwd)"    # Папка, откуда запущен инсталлятор — она же папка с исходниками
FILE_NAME="${APP_NAME%.*}"



# ---- Переиспользуем общую библиотеку проекта --------------------------------
# Инсталлятор поставляется рядом с исходниками, поэтому kopia_common.sh
# уже лежит в той же папке, что и сам install.sh. Берём отсюда REAL_HOME,
# require_root, exit_with_msg и цвета — не дублируем эту логику.
if [[ ! -f "${APP_DIR}/kopia_common.sh" ]]; then
    echo "ОШИБКА: не найден kopia_common.sh рядом с ${APP_NAME}. Установка невозможна." >&2
    exit 1
fi
source "${APP_DIR}/kopia_common.sh"



# ---- Список файлов проекта ---------------------------------------------------
FILES_TO_INSTALL=("kopia_common.sh" "kopia_backup.sh" "kopia_restore_to.sh")
EXECUTABLE_FILES=("kopia_backup.sh" "kopia_restore_to.sh")
NON_EXECUTABLE_FILES=("kopia_common.sh")



# ---- Справка и использование (функции, а не заранее вычисляемые переменные) -
print_usage() {
    echo "Использование: ${APP_NAME} [-h|--help] [--usage] [-v|--version] [ПУТЬ_УСТАНОВКИ]"
}

print_help() {
    print_usage
cat <<EOF

${APP_TITLE}
${APP_NAME} — установка скриптов резервного копирования kopia.

Ключи:
  -h, --help       показать эту справку и выйти
      --usage      показать краткую строку использования и выйти
  -v, --version    показать версию и выйти

Аргументы:
  ПУТЬ_УСТАНОВКИ   необязательный. Произвольная папка для установки.
                   Если не передан — предлагается интерактивный выбор
                   из трёх вариантов:

                     1) /usr/bin/              (нужен root, не рекомендуется)
                     2) \$HOME/bin/             (рекомендуется)
                     3) \$HOME/.local/bin/      (опционально)

Примеры:
  ${APP_NAME}
      Показать интерактивное меню выбора папки.

  ${APP_NAME} /opt/kopia-scripts
      Установить в указанную папку без вопросов о выборе варианта.

Что делает установка:
  - копирует kopia_common.sh, kopia_backup.sh, kopia_restore_to.sh
    в целевую папку;
  - устанавливает флаг исполнения на kopia_backup.sh и
    kopia_restore_to.sh;
  - снимает флаг исполнения с kopia_common.sh (он только подключается
    через source, самостоятельно не запускается).
EOF
}



# ---- Разбор аргументов командной строки -------------------------------------
case "${1:-}" in
    -h|--help)
        print_help
        exit 0
        ;;
    --usage)
        print_usage
        exit 0
        ;;
    -v|--version)
        print_version
        exit 0
        ;;
esac



# ---- Проверка наличия исходных файлов ---------------------------------------
for f in "${FILES_TO_INSTALL[@]}"; do
    if [[ ! -f "${APP_DIR}/${f}" ]]; then
        exit_with_msg "Не найден исходный файл: ${APP_DIR}/${f}" 1
    fi
done



# ---- Определение целевой папки установки ------------------------------------
TARGET_DIR="${1:-}"

if [[ -z "$TARGET_DIR" ]]; then
    echo "Выберите папку установки:"
    echo "  1) /usr/bin/              (требуется root, не рекомендуется)"
    echo "  2) \$HOME/bin/             (рекомендуется)"
    echo "  3) \$HOME/.local/bin/      (опционально)"
    read -r -p "Ваш выбор [1-3]: " CHOICE

    case "$CHOICE" in
        1) TARGET_DIR="/usr/bin" ;;
        2) TARGET_DIR="${REAL_HOME}/bin" ;;
        3) TARGET_DIR="${REAL_HOME}/.local/bin" ;;
        *) exit_with_msg "Некорректный выбор: ${CHOICE}" 1 ;;
    esac
fi



# ---- Создание целевой папки, с эскалацией прав при необходимости -----------
# Не гадаем заранее, нужен ли root для конкретного пути (жёсткая проверка
# по префиксу вида "/usr/bin*" не покрыла бы, например, /opt/...). Вместо
# этого пробуем создать папку и ЯВНО проверяем право на запись в неё.
#
# ВАЖНО: `mkdir -p` возвращает успех (код 0), если папка уже существует,
# даже если у нас нет прав писать в неё (типичный случай для /usr/bin,
# которая почти всегда уже создана root'ом). Поэтому одной проверки кода
# возврата mkdir недостаточно — обязательно проверяем -w отдельно.
MKDIR_ERR="$(mkdir -p "$TARGET_DIR" 2>&1 1>/dev/null)"
MKDIR_STATUS=$?

if [[ $MKDIR_STATUS -ne 0 ]] || [[ ! -w "$TARGET_DIR" ]]; then
    if [[ "$(id -u)" -ne 0 ]]; then
        echo "Нет прав на запись в '${TARGET_DIR}' — перезапуск через sudo..."
        # Передаём уже определённый TARGET_DIR явным аргументом, чтобы после
        # перезапуска через sudo не показывать интерактивное меню заново.
        require_root "$TARGET_DIR"
    else
        exit_with_msg "Не удалось создать/получить доступ на запись к папке: ${TARGET_DIR}${MKDIR_ERR:+ (${MKDIR_ERR})}" 1
    fi
fi



# ---- Проверка на переустановку/обновление -----------------------------------
NEED_CONFIRM=false
for f in "${FILES_TO_INSTALL[@]}"; do
    SRC_FILE="${APP_DIR}/${f}"
    DST_FILE="${TARGET_DIR}/${f}"

    if [[ -e "$DST_FILE" ]]; then
        # Если источник и назначение — один и тот же файл (например,
        # инсталлятор запущен прямо из уже установленной папки) — не
        # считаем это переустановкой, просто пропустим копирование ниже.
        if [[ "$(realpath "$SRC_FILE" 2>/dev/null)" == "$(realpath "$DST_FILE" 2>/dev/null)" ]]; then
            continue
        fi
        NEED_CONFIRM=true
        break
    fi
done

if $NEED_CONFIRM; then
    echo "В папке '${TARGET_DIR}' уже есть файлы проекта — похоже на переустановку/обновление."
    read -r -p "Перезаписать существующие файлы? (y/N): " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]([Ee][Ss])?$ ]]; then
        exit_with_msg "Установка отменена пользователем." 1
    fi
fi



# ---- Копирование файлов -------------------------------------------------------
for f in "${FILES_TO_INSTALL[@]}"; do
    SRC_FILE="${APP_DIR}/${f}"
    DST_FILE="${TARGET_DIR}/${f}"

    if [[ -e "$DST_FILE" ]] && [[ "$(realpath "$SRC_FILE" 2>/dev/null)" == "$(realpath "$DST_FILE" 2>/dev/null)" ]]; then
        echo "Пропуск: ${f} уже находится в целевой папке."
        continue
    fi

    cp -f "$SRC_FILE" "$DST_FILE" || exit_with_msg "Не удалось скопировать ${f} в ${TARGET_DIR}" 1
    echo "Скопирован: ${f} -> ${TARGET_DIR}/${f}"
done



# ---- Права на исполнение ------------------------------------------------------
for f in "${EXECUTABLE_FILES[@]}"; do
    chmod +x "${TARGET_DIR}/${f}" || exit_with_msg "Не удалось установить флаг исполнения на ${f}" 1
done

for f in "${NON_EXECUTABLE_FILES[@]}"; do
    chmod -x "${TARGET_DIR}/${f}" || exit_with_msg "Не удалось снять флаг исполнения с ${f}" 1
done



# ---- Проверка $PATH и финальное сообщение -----------------------------------
echo ""
echo "Установка завершена в: ${TARGET_DIR}"

if [[ ":${PATH}:" != *":${TARGET_DIR}:"* ]]; then
    echo ""
    echo "ВНИМАНИЕ: папка '${TARGET_DIR}' отсутствует в текущем \$PATH."
    echo "Добавьте строку ниже в ~/.bashrc или ~/.profile и перелогиньтесь"
    echo "(либо выполните её в текущей сессии, чтобы не перезапускать терминал):"
    echo ""
    echo "    export PATH=\"${TARGET_DIR}:\$PATH\""
fi

echo ""
echo "Дальнейшие шаги:"
echo "  1. Создайте файл пароля репозитория:"
echo "       mkdir -p ${REAL_HOME}/.config/kopia_backup"
echo "       echo 'ваш-пароль' > ${REAL_HOME}/.config/kopia_backup/.kopia_pass"
echo "       chmod 600 ${REAL_HOME}/.config/kopia_backup/.kopia_pass"
echo "  2. Запустите kopia_backup.sh — первый запуск создаст шаблон конфига"
echo "     для редактирования и остановится."
echo "  3. Отредактируйте конфиг при необходимости и запустите ещё раз."

exit 0
