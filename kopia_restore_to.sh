#!/usr/bin/env bash
#
# kopia_restore_to.sh
# ------------------------------------------------------------------------------
# Восстановление данных из репозитория kopia.
#
# Два режима работы:
#
#   1. Автоматическое восстановление (restore-kit найден):
#        kopia_restore_to.sh --repo <архив> --to <куда>
#      Скрипт находит restore-kit (внутри репозитория или рядом с ним),
#      подключается по repository.config из него, берёт пароль из
#      .kopia_pass, читает список путей из source_paths.txt и
#      восстанавливает все пути в указанный каталог с сохранением
#      исходной структуры.
#
#   2. Работа без restore-kit (старый/чужой архив, есть только пароль):
#        kopia_restore_to.sh --repo <архив> --password-file <файл> --list
#        kopia_restore_to.sh --repo <архив> --password-file <файл> --manifest
#        kopia_restore_to.sh --repo <архив> --password-file <файл> --mount <точка>
#      Скрипт подключается к репозиторию и показывает его содержимое
#      (список снапшотов / манифест) либо монтирует для ручного
#      копирования. Решение о том, что извлекать, принимает
#      администратор.
#
# Во всех случаях подключение к репозиторию выполняется с временным
# repository.config (mktemp -d), который не пересекается с локальным
# конфигом kopia. Это исключает конфликт между локальным и внешним
# репозиторием.
#
# Скрипт интерактивный: --mount блокирует терминал до Ctrl-C (Kopia
# сама размонтирует точку по сигналу). Никаких фоновых процессов.
#
#   Поведение при отсутствии конфига:
#     Если $CONFIG_FILE не существует, вызывается save_config_file(),
#     которая создаёт ШАБЛОН конфига (с дефолтными путями, не
#     отражающими реальную структуру текущей системы) и ЗАВЕРШАЕТ
#     скрипт с кодом 0 и сообщением «отредактируйте и запустите
#     заново». Это сделано намеренно: пользователь должен осознанно
#     пройти через редактирование, а не запустить бэкап с дефолтными
#     путями, которые могут оказаться неверными.
#     После этого пользователь запускает `-ec` ещё раз — теперь
#     конфиг существует, и edit_config_file открывает его в редакторе.
#
# ------------------------------------------------------------------------------
#

set -uo pipefail



APP_TITLE="Скрипт восстановления данных из резервной копии. Обёртка для Kopia - Fast And Secure Open-Source Backup"

APP_NAME="$(basename "$0")"                 # Имя скрипта, включая расширение
APP_DIR="$(cd "$(dirname "$0")" && pwd)"    # Папка размещения скрипта



# ---- Справка и использование ------------------------------------------------
print_usage() {
    echo "Использование: ${APP_NAME} --repo <архив> [ОПЦИИ]"
    echo "               ${APP_NAME} --repo <архив> [--password-file <файл>] [-i|--info [ПУТЬ]]"
    echo "               ${APP_NAME} -ec|--edit_config"
    echo "               ${APP_NAME} -h|--help | -v|--version"
}



print_help() {
    print_usage
cat <<EOF

${APP_TITLE}
${APP_NAME} — восстановление данных из репозитория kopia.

ОБЯЗАТЕЛЬНЫЙ ПАРАМЕТР:
  --repo <путь>          Путь к каталогу репозитория kopia (архив).
                         Может быть локальным бэкапом или архивом
                         с другой машины, скопированным на этот хост.

ПРОСМОТР ИНФОРМАЦИИ ОБ АРХИВЕ:
  -i, --info [ПУТЬ]      Показать информацию об архиве без восстановления:
                         дату последнего снапшота, размер данных, число
                         файлов/папок. Без ПУТИ — сводка по всем путям из
                         source_paths.txt (если restore-kit найден) или по
                         одному пути, если он указан. С ПУТЬЮ — то же плюс
                         список файлов/папок верхнего уровня в снапшоте
                         (kopia ls, не рекурсивно).

РЕЖИМ 1 — автоматическое восстановление (restore-kit найден):
  --to <путь>            Каталог, в который восстановить все пути из
                         source_paths.txt (список внутри restore-kit).
                         Структура путей сохраняется:
                         /etc -> <--to>/etc, /home/ar -> <--to>/home/ar

РЕЖИМ 2 — работа без restore-kit (старый/чужой архив):
  --password-file <файл> Файл с паролем репозитория (chmod 600).
                         Обязателен, если restore-kit не найден.
  --list                 Показать список всех снапшотов в репозитории
                         (kopia snapshot list --all) и выйти.
  --manifest             Показать манифест репозитория
                         (kopia manifest list) и выйти.
  --mount <точка>        Примонтировать весь репозиторий (все последние
                         снапшоты) в указанную точку для ручного
                         копирования. Скрипт блокируется до Ctrl-C;
                         Kopia сама размонтирует точку по сигналу.

ДОПОЛНИТЕЛЬНО:
  --kit <путь>           Явно указать каталог restore-kit (если он лежит
                         не внутри репозитория и не рядом с ним).
  -ec, --edit_config     Открыть конфиг-файл обёртки в редакторе 
                         (переменная EDITOR из пользовательского конфига)
                         и выйти. Редактирование выполняется от имени 
                         пользователя, не от root.
                         После сохранения запустите скрипт заново.
  -h|--help              Показать эту справку и выйти.
  -v|--version           Показать версию скрипта и выйти.

ПРИМЕРЫ:
  # Автоматическое восстановление чужого архива:
  ${APP_NAME} --repo /mnt/usb/archive --to /mnt/restore

  # Посмотреть, что есть в архиве (restore-kit не найден):
  ${APP_NAME} --repo /mnt/usb/archive --password-file /root/.pass --list

  # Примонтировать архив и скопировать нужное вручную:
  ${APP_NAME} --repo /mnt/usb/archive --password-file /root/.pass --mount /mnt/view

  # Посмотреть информацию о снапшоте /etc в чужом архиве:
  ${APP_NAME} --repo /mnt/usb/archive --password-file /root/.pass -i /etc

  # Сводка по всем путям из source_paths.txt (restore-kit найден):
  ${APP_NAME} --repo /mnt/usb/archive -i

ФАЙЛЫ:
  kopia_common.sh   — общие настройки и функции (read_source_paths_file,
                      check_kopia_password_file и т.д.).

Версия: ${APP_VERSION}
${COPYRIGHT}
EOF
}



# ---- Подключаем общий конфиг ------------------------------------------------
# shellcheck disable=SC1091
source "${APP_DIR}/kopia_common.sh"



# ------------------------------------------------------------------------------
# print_archive_info "путь"
#
#   Показывает информацию об архиве без восстановления данных:
#     - дату последнего снапшота (startTime);
#     - размер данных и число файлов/папок (stats), если kopia их отдаёт;
#     - если передан конкретный путь — список файлов/папок верхнего
#       уровня внутри этого снапшота (kopia ls, не рекурсивно).
#
#   Без аргумента проходит по всем путям из source_paths.txt (restore-kit)
#   или по SOURCE_PATHS_FROM_FILE, если он уже прочитан. С аргументом —
#   только по указанному пути.
#
#   Требует, чтобы KOPIA_CONFIG уже указывал на подключённый репозиторий.
# ------------------------------------------------------------------------------
print_archive_info() {
    local target_path="${1:-}"
    local -a paths_to_show=()

    if [[ -n "$target_path" ]]; then
        paths_to_show=("$target_path")
    else
        # Если ранее прочитан source_paths.txt — используем его.
        # Иначе — пусто (покажем сообщение ниже).
        if (( ${#SOURCE_PATHS_FROM_FILE[@]} > 0 )); then
            paths_to_show=("${SOURCE_PATHS_FROM_FILE[@]}")
        fi
    fi

    if (( ${#paths_to_show[@]} == 0 )); then
        echo "Нет путей для показа. Укажите путь: ${APP_NAME} --info /etc"
        echo "или используйте --list для просмотра всех снапшотов в репозитории."
        return 0
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



# ---- Разбор аргументов ------------------------------------------------------
REPO_PATH_ARG=""
TO_ARG=""
PASSWORD_FILE_ARG=""
KIT_ARG=""
MOUNT_ARG=""
ACTION_LIST="no"
ACTION_MANIFEST="no"
ACTION_INFO="no"
INFO_PATH_ARG=""
ORIG_ARGS=("$@")    # Сохранение параметров выхова для переключения в require_root "$@"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -v|--version)
            print_version
            exit 0
            ;;

        -h|--help)
            print_help
            exit 0
            ;;

        # -ec не требует --repo, поэтому проверка --repo должна идти после обработки -ec. 
        -ec|--edit_config)
            edit_config_file
            exit_with_msg "Конфиг-файл отредактирован: ${CONFIG_FILE}. Запустите скрипт заново, чтобы применить изменения." 0
            ;;

        --repo)
            [[ $# -ge 2 ]] || { echo "Ошибка: --repo требует аргумент" >&2; exit 2; }
            REPO_PATH_ARG="$2"
            shift 2
            ;;

        -i|--info)
            ACTION_INFO="yes"
            # Необязательный аргумент: если следующий не начинается с '-',
            # считаем его путём для --info.
            if [[ $# -ge 2 && "${2:-}" != -* ]]; then
                INFO_PATH_ARG="$2"
                shift 2
            else
                INFO_PATH_ARG=""
                shift
            fi
            ;;

        --to)
            [[ $# -ge 2 ]] || { echo "Ошибка: --to требует аргумент" >&2; exit 2; }
            TO_ARG="$2"
            shift 2
            ;;

        --password-file)
            [[ $# -ge 2 ]] || { echo "Ошибка: --password-file требует аргумент" >&2; exit 2; }
            PASSWORD_FILE_ARG="$2"
            shift 2
            ;;

        --kit)
            [[ $# -ge 2 ]] || { echo "Ошибка: --kit требует аргумент" >&2; exit 2; }
            KIT_ARG="$2"
            shift 2
            ;;

        --mount)
            [[ $# -ge 2 ]] || { echo "Ошибка: --mount требует аргумент" >&2; exit 2; }
            MOUNT_ARG="$2"
            shift 2
            ;;

        --list)
            ACTION_LIST="yes"
            shift
            ;;

        --manifest)
            ACTION_MANIFEST="yes"
            shift
            ;;

        *)
            echo "Неизвестный аргумент: $1" >&2
            print_usage >&2
            exit 2
            ;;
    esac
done

# Проверка обязательного --repo
if [[ -z "$REPO_PATH_ARG" ]]; then
    echo "Ошибка: обязательный параметр --repo не задан." >&2
    print_usage >&2
    exit 2
fi

# Проверка существования репозитория
if [[ ! -d "$REPO_PATH_ARG" ]]; then
    exit_with_msg "Каталог репозитория не найден: ${REPO_PATH_ARG}" 1
fi

# kopia для filesystem-бэкенда требует АБСОЛЮТНЫЙ путь к репозиторию.
# Если пользователь передал относительный (например, Backups/...),
# канонизируем его через realpath. realpath также разворачивает
# символические ссылки, что корректно: kopia сохранит в repository.config
# реальный путь к данным.
REPO_PATH_ARG="$(realpath "$REPO_PATH_ARG")" || \
    exit_with_msg "Не удалось определить абсолютный путь к ${REPO_PATH_ARG}" 1

if [[ ! -f "${REPO_PATH_ARG}/kopia.repository.f" ]]; then
    exit_with_msg "В ${REPO_PATH_ARG} нет kopia.repository.f — это не репозиторий kopia." 1
fi

# Проверка: действия --list / --manifest / --mount / --info взаимоисключающие
_actions_count=0
[[ "$ACTION_LIST" == "yes" ]] && _actions_count=$((_actions_count + 1))
[[ "$ACTION_MANIFEST" == "yes" ]] && _actions_count=$((_actions_count + 1))
[[ -n "$MOUNT_ARG" ]] && _actions_count=$((_actions_count + 1))
[[ "$ACTION_INFO" == "yes" ]] && _actions_count=$((_actions_count + 1))

if (( _actions_count > 1 )); then
    exit_with_msg "Ключи --list, --manifest, --mount и --info взаимоисключающие. Укажите только один." 1
fi


# shellcheck disable=SC2329
cleanup_temp() {
    rm -rf "$TEMP_DIR"
}
trap cleanup_temp EXIT



# ---- Самоповышение прав -----------------------------------------------------
# Для чтения репозитория и записи в --to обычно нужен root
# (архив может содержать /etc, /root и т.п.).
require_root "${ORIG_ARGS[@]}"



# ---- Подготовка временного конфига kopia ------------------------------------
# Всегда используем отдельный временный repository.config, чтобы не
# пересекаться с локальным конфигом (~/.config/kopia_backup/repository.config).
# Временный каталог удаляется по trap EXIT.
TEMP_DIR="$(mktemp -d)" || exit_with_msg "Не удалось создать временный каталог" 1
KOPIA_CONFIG="${TEMP_DIR}/${KOPIA_CONFIG_FILENAME}"



# ---- 0. Проверка необходимых программ --------------------------------------
check_required_packages



# ---- 1. Поиск restore-kit ---------------------------------------------------
# Приоритет:
#   1) --kit PATH (явно указан пользователем);
#   2) <repo>/restore_kit/repository.config (mode=in);
#   3) <repo>.restore_kit/repository.config (mode=out).
KIT_DIR=""
if [[ -n "$KIT_ARG" ]]; then
    if [[ -f "${KIT_ARG}/${KOPIA_CONFIG_FILENAME}" ]]; then
        KIT_DIR="$KIT_ARG"
    else
        exit_with_msg "В ${KIT_ARG} нет ${KOPIA_CONFIG_FILENAME} — это не restore-kit." 1
    fi
elif [[ -f "${REPO_PATH_ARG}/${RESTORE_KIT_DIR_NAME}/${KOPIA_CONFIG_FILENAME}" ]]; then
    KIT_DIR="${REPO_PATH_ARG}/${RESTORE_KIT_DIR_NAME}"
elif [[ -f "${REPO_PATH_ARG}.${RESTORE_KIT_DIR_NAME}/${KOPIA_CONFIG_FILENAME}" ]]; then
    KIT_DIR="${REPO_PATH_ARG}.${RESTORE_KIT_DIR_NAME}"
fi

# ---- 2. Определение KOPIA_PASSWORD_FILE ------------------------------------
if [[ -n "$KIT_DIR" ]]; then
    echo "Найден restore-kit: ${KIT_DIR}"
    if [[ ! -f "${KIT_DIR}/.kopia_pass" ]]; then
        exit_with_msg "В restore-kit ${KIT_DIR} нет .kopia_pass — восстановление невозможно." 1
    fi
    KOPIA_PASSWORD_FILE="${KIT_DIR}/.kopia_pass"
else
    if [[ -z "$PASSWORD_FILE_ARG" ]]; then
        exit_with_msg "restore-kit не найден, а --password-file не задан. Укажите пароль или --kit." 1
    fi
    if [[ ! -f "$PASSWORD_FILE_ARG" ]]; then
        exit_with_msg "Файл пароля не найден: ${PASSWORD_FILE_ARG}" 1
    fi
    KOPIA_PASSWORD_FILE="$PASSWORD_FILE_ARG"
fi

# Проверка прав файла пароля
check_kopia_password_file



# ---- 3. Подключение к репозиторию ------------------------------------------
echo "Подключение к репозиторию: ${REPO_PATH_ARG}"
KOPIA_PASSWORD="$(cat "$KOPIA_PASSWORD_FILE")"
export KOPIA_PASSWORD

kopia repository connect filesystem \
    --path "$REPO_PATH_ARG" \
    --config-file "$KOPIA_CONFIG" || {
        exit_with_msg "Не удалось подключиться к репозиторию ${REPO_PATH_ARG}" 1
    }

echo ""



# ---- 4.0. Действие --info (просмотр информации об архиве) -------------------
if [[ "$ACTION_INFO" == "yes" ]]; then
    # Если restore-kit найден и есть source_paths.txt — читаем его,
    # чтобы без аргумента показать сводку по всем путям.
    if [[ -n "$KIT_DIR" && -f "${KIT_DIR}/source_paths.txt" ]]; then
        read_source_paths_file "${KIT_DIR}/source_paths.txt" || true
    fi

    print_archive_info "$INFO_PATH_ARG"
    exit 0
fi



# ---- 5. Действия без restore-kit (--list / --manifest / --mount) -----------
if [[ "$ACTION_LIST" == "yes" ]]; then
    echo "Снапшоты в репозитории:"
    echo "-----------------------------------"
    kopia snapshot list --all --config-file "$KOPIA_CONFIG"
    echo "-----------------------------------"
    exit 0
fi

if [[ "$ACTION_MANIFEST" == "yes" ]]; then
    echo "Манифест репозитория:"
    echo "-----------------------------------"
    kopia manifest list --config-file "$KOPIA_CONFIG"
    echo "-----------------------------------"
    exit 0
fi

if [[ -n "$MOUNT_ARG" ]]; then
    # Канонизируем точку монтирования в абсолютный путь.
    # Создаём каталог, если его нет — kopia mount (fusermount3)
    # НЕ создаёт точку монтирования автоматически.
    mkdir -p "$MOUNT_ARG" || \
        exit_with_msg "Не удалось создать точку монтирования: ${MOUNT_ARG}" 1
    MOUNT_ARG="$(realpath "$MOUNT_ARG")" || \
        exit_with_msg "Не удалось определить абсолютный путь к ${MOUNT_ARG}" 1

    echo "Монтирование репозитория в: ${MOUNT_ARG}"
    echo "Скопируйте нужные данные, затем нажмите Ctrl-C для размонтирования."
    echo ""

    kopia mount all "$MOUNT_ARG" --config-file "$KOPIA_CONFIG" || {
        exit_with_msg "Ошибка при монтировании репозитория в ${MOUNT_ARG}" 1
    }

    echo "Архив размонтирован."
    exit 0
fi



# ---- 6. Автоматическое восстановление (нужен restore-kit и --to) -----------
if [[ -z "$KIT_DIR" ]]; then
    exit_with_msg "restore-kit не найден. Для восстановления нужен restore-kit или укажите --list / --manifest / --mount." 1
fi

if [[ -z "$TO_ARG" ]]; then
    exit_with_msg "Не задан --to (каталог для восстановления)." 1
fi

# Чтение списка путей из source_paths.txt
if ! read_source_paths_file "${KIT_DIR}/source_paths.txt"; then
    exit_with_msg "В restore-kit ${KIT_DIR} нет source_paths.txt — не знаем, что восстанавливать." 1
fi

if (( ${#SOURCE_PATHS_FROM_FILE[@]} == 0 )); then
    exit_with_msg "source_paths.txt в restore-kit пуст — нечего восстанавливать." 1
fi

echo "Восстановление будет выполнено в: ${TO_ARG}"
echo "Пути из source_paths.txt:"
printf '  %s\n' "${SOURCE_PATHS_FROM_FILE[@]}"
echo ""

# Защита от перезаписи непустого каталога
if [[ -d "$TO_ARG" && -n "$(ls -A "$TO_ARG" 2>/dev/null)" ]]; then
    echo "ВНИМАНИЕ: директория ${TO_ARG} уже существует и не пуста." >&2
    read -r -p "Продолжить и восстановить поверх? (y/N): " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]([Ee][Ss])?$ ]]; then
        exit_with_msg "Отменено пользователем." 1
    fi
fi

mkdir -p "$TO_ARG"

FAILED=()
for SRC in "${SOURCE_PATHS_FROM_FILE[@]}"; do
    echo "-----------------------------------"
    echo "Обработка: $SRC"

    LATEST_ID=$(kopia snapshot list "$SRC" --config-file "$KOPIA_CONFIG" --json 2>/dev/null \
        | jq -r 'max_by(.startTime) | .id // empty')

    if [[ -z "$LATEST_ID" ]]; then
        echo "ПРОПУСК: снапшоты для $SRC не найдены" >&2
        FAILED+=("$SRC")
        continue
    fi

    DEST="${TO_ARG}${SRC}"
    mkdir -p "$(dirname "$DEST")"

    echo "Снапшот: $LATEST_ID -> $DEST"

    if ! kopia snapshot restore "$LATEST_ID" "$DEST" --config-file "$KOPIA_CONFIG"; then
        echo "ОШИБКА: восстановление $SRC не удалось" >&2
        FAILED+=("$SRC")
        continue
    fi
done

echo "-----------------------------------"
echo "Готово. Данные восстановлены в: ${TO_ARG}"

if (( ${#FAILED[@]} > 0 )); then
    exit_with_msg "Не удалось восстановить: ${FAILED[*]}" 1
fi

exit 0
