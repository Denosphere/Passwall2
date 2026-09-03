#!/usr/bin/env bash
# Обновление пакетов Passwall2 из репозитория апстрима.
#
# Два способа запуска, логика одна и та же:
#   1. GitHub: вкладка Actions -> "Обновление пакетов" -> Run workflow.
#      С машины то же самое одной командой:
#        gh workflow run update-packages.yml -R Denosphere/Passwall2
#   2. Локально, из клона этого репозитория:
#        ./update-packages.sh
#
# Что делает:
#   1. Находит свежий релиз в Openwrt-Passwall/openwrt-passwall2
#   2. Качает luci-app-passwall2 и русскую локализацию - отдельными ассетами
#   3. Качает архив пакетов под нужную архитектуру и достаёт из него
#      geoview, tcping, xray-core - те, что там есть
#   4. Кладёт всё рядом с собой под короткими именами
#   5. Показывает таблицу версий до и после
#
# Коммит не делает: локально - вручную, в Actions - отдельным шагом workflow.
#
# Использование:
#   ./update-packages.sh                        # последний релиз, aarch64_cortex-a53
#   ./update-packages.sh --arch arm_cortex-a7   # другая архитектура
#   ./update-packages.sh --tag 26.7.12-1        # конкретная версия
#   ./update-packages.sh --list                 # только показать, что есть в релизе

set -euo pipefail

REPO="Openwrt-Passwall/openwrt-passwall2"
ARCH="aarch64_cortex-a53"
TAG=""
LIST_ONLY=0

# Пакеты из zip-архива. Апстрим кладёт туда не всё и не всегда: xray-core,
# например, пропал из архива после релиза 26.8.10-1. Если пакета нет - остаётся
# лежать прежняя версия, это не повод считать запуск неудачным.
FROM_ZIP="geoview tcping xray-core"

# Пакеты лежат рядом со скриптом, в корне этого репозитория.
DEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

while [ $# -gt 0 ]; do
  case "$1" in
    --arch) ARCH="$2"; shift 2 ;;
    --tag)  TAG="$2";  shift 2 ;;
    --list) LIST_ONLY=1; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "Неизвестный аргумент: $1"; exit 1 ;;
  esac
done

command -v gh    >/dev/null || { echo "ОШИБКА: нет gh CLI"; exit 1; }
command -v unzip >/dev/null || { echo "ОШИБКА: нет unzip"; exit 1; }

if [ -z "$TAG" ]; then
  TAG=$(gh release view -R "$REPO" --json tagName -q .tagName)
fi

echo "Репозиторий: $REPO"
echo "Релиз:       $TAG"
echo "Архитектура: $ARCH"
echo "Назначение:  $DEST"
echo

if [ "$LIST_ONLY" = 1 ]; then
  echo "=== ассеты релиза ==="
  gh release view "$TAG" -R "$REPO" --json assets -q '.assets[].name'
  exit 0
fi

# Версия из control внутри .ipk, или "нет" / "?" если прочитать не удалось.
current_version() {
  [ -f "$1" ] || { echo "нет"; return; }
  local t v
  t=$(mktemp -d)
  tar -xzf "$1" -C "$t" 2>/dev/null || { rm -rf "$t"; echo "?"; return; }
  v=""
  if [ -f "$t/control.tar.gz" ]; then
    tar -xzf "$t/control.tar.gz" -C "$t" 2>/dev/null || true
    v=$(grep -m1 '^Version:' "$t/control" 2>/dev/null | awk '{print $2}' || true)
  fi
  rm -rf "$t"
  echo "${v:-?}"
}

ALL="luci-app-passwall2 luci-i18n-passwall2-ru $FROM_ZIP"

print_versions() {
  for f in $ALL; do
    printf "  %-25s %s\n" "$f" "$(current_version "$DEST/$f.ipk")"
  done
}

echo "=== версии до обновления ==="
print_versions
echo

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Копирует найденный по маске файл в репозиторий под коротким именем.
take() {
  local dir="$1" mask="$2" name="$3" src
  src=$(find "$dir" -type f -name "$mask" | head -1)
  [ -n "$src" ] || return 1
  cp "$src" "$DEST/$name.ipk"
  echo "  $(basename "$src")  ->  $name.ipk"
}

echo "=== качаю luci-app и локализацию ==="
gh release download "$TAG" -R "$REPO" -D "$WORK" \
  -p "luci-app-passwall2_*_all.ipk" \
  -p "luci-i18n-passwall2-ru_*_all.ipk" --clobber

take "$WORK" "luci-app-passwall2_*_all.ipk" "luci-app-passwall2" \
  || { echo "ОШИБКА: luci-app-passwall2 в релизе $TAG не найден"; exit 1; }
take "$WORK" "luci-i18n-passwall2-ru_*_all.ipk" "luci-i18n-passwall2-ru" \
  || { echo "ОШИБКА: русская локализация в релизе $TAG не найдена"; exit 1; }

ZIP="passwall_packages_ipk_${ARCH}.zip"
echo
echo "=== качаю $ZIP ==="
gh release download "$TAG" -R "$REPO" -D "$WORK" -p "$ZIP" --clobber

echo "=== распаковываю ==="
unzip -q -o "$WORK/$ZIP" -d "$WORK/unpacked"

echo "=== достаю пакеты из архива ==="
for pkg in $FROM_ZIP; do
  take "$WORK/unpacked" "${pkg}_*.ipk" "$pkg" \
    || echo "  $pkg в архиве отсутствует - оставляю прежнюю версию"
done

echo
echo "=== версии после обновления ==="
print_versions

echo
echo "=== что изменилось ==="
git -C "$DEST" status --short

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "tag=$TAG" >> "$GITHUB_OUTPUT"
fi

if [ -z "${GITHUB_ACTIONS:-}" ]; then
  echo
  echo "Пакеты обновлены локально, но НЕ закоммичены. Закоммитить и отправить:"
  echo "  git -C \"$DEST\" add -A"
  echo "  git -C \"$DEST\" commit -m \"Обновление пакетов до $TAG\""
  echo "  git -C \"$DEST\" push"
fi
