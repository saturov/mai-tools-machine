import argparse
import asyncio
import os
import sys
from datetime import datetime, timezone
from typing import Dict, Optional, Tuple

from telethon import TelegramClient
from telethon.errors import (ChannelPrivateError, FloodWaitError,
                             RPCError, UsernameInvalidError,
                             UsernameNotOccupiedError)
from telethon.tl.functions.channels import JoinChannelRequest
from telethon.tl.types import MessageMediaPhoto


EXIT_INVALID_CREDENTIALS = 2
EXIT_CHANNEL_ERROR = 3
EXIT_NETWORK_ERROR = 4
EXIT_FILE_WRITE_ERROR = 5


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Выгрузка истории Telegram-канала в TXT"
    )
    parser.add_argument(
        "--channel",
        required=True,
        help="@username или t.me/<slug> канала",
    )
    parser.add_argument(
        "--output",
        help="Путь к результирующему TXT (по умолчанию export_<slug>.txt)",
    )
    parser.add_argument("--api-id", dest="api_id", type=int, help="Telegram API ID")
    parser.add_argument("--api-hash", dest="api_hash", help="Telegram API HASH")
    parser.add_argument(
        "--session",
        default="tg_export",
        help="Имя файла сессии (по умолчанию tg_export)",
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=None,
        help="Опциональное ограничение числа сообщений для быстрой проверки",
    )
    parser.add_argument(
        "--timeout-seconds",
        type=int,
        default=10,
        help="Сетевой таймаут, сек (по умолчанию 10)",
    )
    parser.add_argument(
        "--no-join",
        dest="no_join",
        action="store_true",
        help="Не пытаться автоматически присоединиться к публичному каналу",
    )
    # Игнорируем разделитель "--", который make может пробрасывать в команду
    argv = [a for a in sys.argv[1:] if a != "--"]
    return parser.parse_args(argv)


def resolve_credentials(args: argparse.Namespace) -> Tuple[int, str]:
    api_id = args.api_id if args.api_id is not None else os.getenv("TG_API_ID")
    api_hash = args.api_hash if args.api_hash is not None else os.getenv("TG_API_HASH")

    try:
        api_id_int = int(api_id) if api_id is not None else None
    except (TypeError, ValueError):
        api_id_int = None

    if not api_id_int or not api_hash:
        print(
            "[error] Требуются TG_API_ID и TG_API_HASH (флаги --api-id/--api-hash или env)",
            file=sys.stderr,
        )
        sys.exit(EXIT_INVALID_CREDENTIALS)

    return api_id_int, str(api_hash)


def normalize_channel(raw: str) -> Tuple[str, str]:
    s = (raw or "").strip()
    s = s.replace("https://", "").replace("http://", "")
    if s.startswith("t.me/"):
        s = s[len("t.me/") :]
    if s.startswith("@"):  # @slug -> slug
        s = s[1:]
    slug = s.split("?")[0].strip("/")
    if not slug:
        print("[error] Некорректный идентификатор канала", file=sys.stderr)
        sys.exit(EXIT_CHANNEL_ERROR)
    return f"@{slug}", slug


def to_iso_z(dt: datetime) -> str:
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    dt_utc = dt.astimezone(timezone.utc)
    return dt_utc.strftime("%Y-%m-%dT%H:%M:%SZ")


def extract_reactions(message) -> Tuple[int, str]:
    reactions = getattr(message, "reactions", None)
    if not reactions or not getattr(reactions, "results", None):
        return 0, ""

    total = 0
    breakdown: Dict[str, int] = {}

    for item in reactions.results:
        count = getattr(item, "count", 0) or getattr(item, "count", 0)
        total += int(count)
        kind = getattr(item, "reaction", None)
        emoji_key = None
        # ReactionEmoji has .emoticon, ReactionCustomEmoji has .document_id (не отображаем)
        if kind is not None and hasattr(kind, "emoticon"):
            emoji_key = getattr(kind, "emoticon")
        if emoji_key:
            breakdown[emoji_key] = breakdown.get(emoji_key, 0) + int(count)

    breakdown_str = ", ".join(f"{k}={v}" for k, v in breakdown.items())
    return total, breakdown_str


def has_non_photo_attachment(message) -> bool:
    media = getattr(message, "media", None)
    if media is None:
        return False
    return not isinstance(media, MessageMediaPhoto)


def build_output_path(explicit_path: str, slug: str) -> str:
    if explicit_path:
        return explicit_path
    return f"export_{slug}.txt"


async def try_join_if_needed(client: TelegramClient, target: str) -> None:
    try:
        await client(JoinChannelRequest(target))
    except RPCError as e:
        # Игнорируем, если уже состоим или нельзя присоединиться (приватный и т.п.)
        return


async def export_history(
    client: TelegramClient,
    channel_identifier: str,
    output_path: str,
    limit: Optional[int],
) -> None:
    try:
        entity = await client.get_entity(channel_identifier)
    except (UsernameInvalidError, UsernameNotOccupiedError, ChannelPrivateError) as e:
        print(f"[error] Канал не найден или нет доступа: {e}", file=sys.stderr)
        sys.exit(EXIT_CHANNEL_ERROR)
    except RPCError as e:
        print(f"[error] Ошибка при разрешении канала: {e}", file=sys.stderr)
        sys.exit(EXIT_NETWORK_ERROR)

    try:
        with open(output_path, "w", encoding="utf-8", newline="\n") as fout:
            count_written = 0
            async for msg in client.iter_messages(entity, reverse=True):
                if isinstance(limit, int) and limit >= 0 and count_written >= limit:
                    break

                message_id = msg.id
                date_iso = to_iso_z(msg.date)
                text = msg.text or ""
                has_image = "yes" if getattr(msg, "photo", None) is not None else "no"
                has_attach = "yes" if has_non_photo_attachment(msg) else "no"
                reactions_total, reactions_breakdown = extract_reactions(msg)
                replies = getattr(msg, "replies", None)
                comments_count = (
                    int(getattr(replies, "replies", 0)) if replies is not None else 0
                )

                # Запись блока
                fout.write(f"ID: {message_id}\n")
                fout.write(f"DATE_UTC: {date_iso}\n")
                fout.write(f"REACTIONS_TOTAL: {reactions_total}\n")
                fout.write(f"REACTIONS_BREAKDOWN: {reactions_breakdown}\n")
                fout.write(f"COMMENTS_COUNT: {comments_count}\n")
                fout.write(f"HAS_IMAGE: {has_image}\n")
                fout.write(f"HAS_ATTACH: {has_attach}\n")
                fout.write("TEXT:\n")
                fout.write(f"{text}\n\n")
                count_written += 1
    except OSError as e:
        print(f"[error] Ошибка записи файла: {e}", file=sys.stderr)
        sys.exit(EXIT_FILE_WRITE_ERROR)
    except FloodWaitError as e:
        # Пробрасываем выше для общей логики ожидания/повтора
        raise
    except RPCError as e:
        print(f"[error] Сетевая ошибка при выгрузке: {e}", file=sys.stderr)
        sys.exit(EXIT_NETWORK_ERROR)


async def main_async() -> None:
    args = parse_args()
    api_id, api_hash = resolve_credentials(args)
    channel_at, slug = normalize_channel(args.channel)
    output_path = build_output_path(args.output, slug)

    # Инициализация клиента
    client = TelegramClient(
        args.session,
        api_id,
        api_hash,
        device_model="tg-scraper",
        system_version="tg-scraper",
        app_version="1.0",
        timeout=args.timeout_seconds,
    )

    # Попытки с учётом FloodWait/сетевых сбоев
    max_attempts = 3
    attempt = 0
    while True:
        attempt += 1
        try:
            await client.start()
            if not args.no_join:
                await try_join_if_needed(client, channel_at)
            await export_history(
                client=client,
                channel_identifier=channel_at,
                output_path=output_path,
                limit=args.limit,
            )
            break
        except FloodWaitError as e:
            wait_seconds = int(getattr(e, "seconds", 0) or 0)
            if wait_seconds <= 0:
                wait_seconds = 5
            print(
                f"[warn] FloodWait: ждём {wait_seconds} сек... (попытка {attempt}/{max_attempts})",
                file=sys.stderr,
            )
            await client.disconnect()
            await asyncio.sleep(wait_seconds)
            if attempt >= max_attempts:
                print("[error] Превышено число попыток после FloodWait", file=sys.stderr)
                sys.exit(EXIT_NETWORK_ERROR)
        except RPCError as e:
            print(
                f"[warn] Сетевая ошибка: {e} (попытка {attempt}/{max_attempts})",
                file=sys.stderr,
            )
            await client.disconnect()
            if attempt >= max_attempts:
                print("[error] Превышено число попыток при сетевой ошибке", file=sys.stderr)
                sys.exit(EXIT_NETWORK_ERROR)
            await asyncio.sleep(2 ** attempt)
        finally:
            # Завершаем соединение при успехе/ошибке
            if client.is_connected():
                await client.disconnect()


def main() -> None:
    try:
        asyncio.run(main_async())
    except KeyboardInterrupt:
        print("[info] Остановлено пользователем", file=sys.stderr)


if __name__ == "__main__":
    main()

 
