#!/usr/bin/env bash
#
# kopia_restore_to.sh
# ------------------------------------------------------------------------------
# Восстанавливает последние снапшоты всех путей из SOURCE_PATHS
# (см. kopia_common.sh) в единую целевую директорию с сохранением
# исходной структуры путей.
#
# Пример: /etc  ->  <RESTORE_ROOT>/etc
#         /home/ar/.config -> <RESTORE_ROOT>/home/ar/.config
#
# Восстановление выполняется в отдельную директорию, а не поверх
# оригинальных путей — это безопаснее и позволяет вручную сверить
# восстановленные данные перед тем, как что-либо перезаписывать.
# ------------------------------------------------------------------------------
#

set -uo pipefail



APP_TITLE="Скрипт восстановления данных из резервной копии. Оёртка для Kopia - Fast And Secure Open-Source Backup"

APP_NAME=$(basename "$0")                   # Имя скрипта, включая расширение
APP_DIR="$(cd "$(dirname "$0")" && pwd)"    # Папка размещения скрипта
FILE_NAME="${APP_NAME%.*}"                  # Убираем расширение (если есть)


# ---- Справка и использование (функции, а не заранее вычисляемые переменные) -
print_usage() {
    echo "Использование: ${APP_NAME} [-h|--help] [-u|--usage] [-v|--version] [-i|--info [ПУТЬ]] [ПУТЬ_ВОССТАНОВЛЕНИЯ]"
}

print_help() {
    print_usage
cat <<EOF

${APP_TITLE}
${APP_NAME} — восстановление последних снапшотов всех путей из SOURCE_PATHS в единую целевую директорию.

При каждом запуске скрипт выводит путь к репозиторию, конфиг-файлу
обёртки и конфигу подключения kopia — для диагностики, какой именно
репозиторий и конфиг используются.

Ключи:
  -h, --help            показать эту справку и выйти
  -u, --usage           показать краткую строку использования и выйти
  -v, --version         показать версию скрипта и выйти
  -i, --info [ПУТЬ]     показать информацию об архиве и выйти, не восстанавливая
                        ничего. Без ПУТИ — сводка по всем SOURCE_PATHS (дата
                        последнего снапшота, размер данных). С ПУТЬЮ — то же
                        самое для конкретного пути, плюс список папок/файлов
                        верхнего уровня внутри этого снапшота.

Аргументы:
  ПУТЬ_ВОССТАНОВЛЕНИЯ   необязательный. Каталог, в который будут
                        восстановлены данные с сохранением исходной
                        структуры путей.
                        По умолчанию: \$HOME/Backups/kopia_restore/<ГГГГММДД_ЧЧММСС>

Примеры:
  ${APP_NAME}
      Восстановить всё в автоматически созданную папку в \$HOME/Backups/kopia_restore/.

  ${APP_NAME} /mnt/data1/restore_test
      Восстановить всё в указанную папку.

  ${APP_NAME} --info
      Показать дату последнего снапшота и размер данных по каждому пути.

  ${APP_NAME} --info /etc
      То же самое для /etc, плюс список файлов/папок верхнего уровня.

Файлы:
  kopia_common.sh   — общие настройки: пути репозитория, список
                      источников резервного копирования, список
                      требуемых программ.

Версия: ${APP_VERSION}
${COPYRIGHT}
EOF
}



# ------------------------------------------------------------------------------
# print_archive_info "путь"
#
#   Показывает информацию об архиве без восстановления данных:
#     - дату последнего снапшота (startTime);
#     - размер данных и число файлов/папок (stats.totalSize/fileCount/dirCount),
#       если kopia их предоставляет;
#     - если передан конкретный путь — дополнительно список файлов и папок
#       верхнего уровня внутри этого снапшота (kopia ls, не рекурсивно).
#
#   Без аргумента проходит по всем SOURCE_PATHS; с аргументом — только по
#   указанному пути.
# ------------------------------------------------------------------------------
print_archive_info() {
    local target_path="${1:-}"
    local paths_to_show=()

    if [[ -n "$target_path" ]]; then
        paths_to_show=("$target_path")
    else
        paths_to_show=("${SOURCE_PATHS[@]}")
    fi

    for SRC in "${paths_to_show[@]}"; do
        echo "-----------------------------------"
        echo "Путь: $SRC"

        local SNAP_JSON LATEST_ID LATEST_DATE LATEST_SIZE LATEST_FILES LATEST_DIRS SIZE_HUMAN
        SNAP_JSON=$(kopia snapshot list "$SRC" --config-file "$KOPIA_CONFIG" --json 2>/dev/null)

        IFS=$'\t' read -r LATEST_ID LATEST_DATE LATEST_SIZE LATEST_FILES LATEST_DIRS <<< "$(
            echo "$SNAP_JSON" | jq -r '
                max_by(.startTime) as $m
                | if $m == null then "\t\t\t\t"
                  else [$m.id, $m.startTime,
                        ($m.rootEntry.summ.size // ""),
                        ($m.rootEntry.summ.files // ""),
                        ($m.rootEntry.summ.dirs // "")] | @tsv
                  end
            '
        )"

        if [[ -z "$LATEST_ID" ]]; then
            echo "  Снапшоты не найдены."
            continue
        fi

        echo "  Дата последнего снапшота: ${LATEST_DATE}"

        if [[ -n "$LATEST_SIZE" ]]; then
            SIZE_HUMAN="$(numfmt --to=iec-i --suffix=B "$LATEST_SIZE" 2>/dev/null)"
            echo "  Размер данных:             ${SIZE_HUMAN:-${LATEST_SIZE} байт} (файлов: ${LATEST_FILES:-?}, папок: ${LATEST_DIRS:-?})"
        else
            echo "  Размер данных:             нет данных"
        fi

        if [[ -n "$target_path" ]]; then
            echo "  Содержимое верхнего уровня:"
            kopia ls "$LATEST_ID" --config-file "$KOPIA_CONFIG" 2>/dev/null | sed 's/^/    /'
        fi
    done
    echo "-----------------------------------"
}



# ---- Подключаем общий конфиг -------------------------------------------------
source "${APP_DIR}/kopia_common.sh"



# ---- Разбор аргументов командной строки -------------------------------------
# Обрабатываем известные информационные ключи; всё остальное, включая
# пустой аргумент, считается путём для восстановления и обрабатывается
# ниже как обычно.
MODE="restore"
INFO_PATH=""

case "${1:-}" in
    -h|--help)
        print_help
        exit 0
        ;;
    -u|--usage)
        print_usage
        exit 0
        ;;
    -v|--version)
        # print_version() определена в kopia_common.sh
        print_version
        exit 0
        ;;
    -i|--info)
        MODE="info"
        INFO_PATH="${2:-}"
        ;;
esac

# ---- Чтение/создание пользовательского конфига -------------------------------
# Выполняется ДО эскалации прав, поэтому файл создаётся и остаётся
# собственностью обычного пользователя — редактировать его можно без sudo.
read_config_file

echo "Путь репозитория     : ${REPO_PATH}"
echo "Конфигурация обёртки : ${CONFIG_FILE}"
echo "Конфигурация kopia   : ${KOPIA_CONFIG}"
echo ""

# ---- Самоповышение прав ------------------------------------------------------
# Если скрипт запущен обычным пользователем — перезапускаем его через sudo.
# Справка/версия и чтение конфига выше отработали без sudo; всё дальнейшее
# требует root.
require_root "$@"

# ---- Целевая папка восстановления --------------------------------------------
# Берём из первого позиционного аргумента; если не передан — берём из конфига
RESTORE_ROOT="${1:-${RESTORE_ROOT_DEFAULT}}"

# ---- 0. Проверка необходимых программ ---------------------------------------
check_required_packages

# ---- 0.1. Проверка файла с паролем репозитория -------------------------------
# Проверяется при каждом запуске: файл должен существовать и иметь права 600.
# При несоответствии — ошибка и exit 1.
check_kopia_password_file

# ---- 1. Проверка подключения к репозиторию -----------------------------------
if ! kopia repository status --config-file "$KOPIA_CONFIG" &>/dev/null; then
    echo "Подключаемся к репозиторию..."
    # Наличие и права файла пароля уже проверены выше функцией check_kopia_password_file.
    KOPIA_PASSWORD="$(cat "$KOPIA_PASSWORD_FILE")"
    export KOPIA_PASSWORD
    kopia repository connect filesystem \
        --path "$REPO_PATH" \
        --config-file "$KOPIA_CONFIG" || {
            exit_with_msg "ОШИБКА: не удалось подключиться к репозиторию" 1
        }
fi

# ---- Режим просмотра информации об архиве (без восстановления) --------------
if [[ "$MODE" == "info" ]]; then
    print_archive_info "$INFO_PATH"
    exit 0
fi

# ---- 2. Защита от случайной перезаписи существующей непустой папки ----------
if [[ -d "$RESTORE_ROOT" && -n "$(ls -A "$RESTORE_ROOT" 2>/dev/null)" ]]; then
    echo "ВНИМАНИЕ: директория $RESTORE_ROOT уже существует и не пуста." >&2
    read -r -p "Продолжить и восстановить поверх? (y/N): " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]([Ee][Ss])?$ ]]; then
        exit_with_msg "Отменено пользователем." 1
    fi
fi

mkdir -p "$RESTORE_ROOT"
echo "Восстановление будет выполнено в: $RESTORE_ROOT"

# ---- 3. Восстановление последнего снапшота каждого пути ----------------------
FAILED=()

for SRC in "${SOURCE_PATHS[@]}"; do
    echo "-----------------------------------"
    echo "Обработка: $SRC"

    # Находим ID самого свежего снапшота для этого пути.
    # max_by явно берёт запись с максимальным startTime — так результат не
    # зависит от того, в каком порядке kopia отдаёт массив по умолчанию.
    LATEST_ID=$(kopia snapshot list "$SRC" --config-file "$KOPIA_CONFIG" --json 2>/dev/null \
        | jq -r 'max_by(.startTime) | .id // empty')

    if [[ -z "$LATEST_ID" ]]; then
        echo "ПРОПУСК: снапшоты для $SRC не найдены" >&2
        FAILED+=("$SRC")
        continue
    fi

    # Целевой путь = RESTORE_ROOT + оригинальный путь (сохраняем структуру)
    DEST="${RESTORE_ROOT}${SRC}"
    mkdir -p "$(dirname "$DEST")"

    echo "Снапшот: $LATEST_ID -> $DEST"

    if ! kopia snapshot restore "$LATEST_ID" "$DEST" --config-file "$KOPIA_CONFIG"; then
        echo "ОШИБКА: восстановление $SRC не удалось" >&2
        FAILED+=("$SRC")
        continue
    fi
done

echo "-----------------------------------"
echo "Готово. Данные восстановлены в: $RESTORE_ROOT"

if (( ${#FAILED[@]} > 0 )); then
    exit_with_msg "Не удалось восстановить: ${FAILED[*]}" 1
fi

exit 0
