#!/usr/bin/env python3
"""core 값 파일의 SPRING_DATASOURCE_HIKARI_MAXIMUM_POOL_SIZE 한 줄만 바꾼다. 줄이 없거나 둘 이상이면 종료 코드 2."""
import re, sys

KEY = r'^(  SPRING_DATASOURCE_HIKARI_MAXIMUM_POOL_SIZE: ")[0-9]+(")[ \t]*$'


def main(argv):
    if len(argv) != 3 or not argv[2].isdigit():
        print("사용법: set_pool.py <values-file> <n>", file=sys.stderr)
        return 2
    path, n = argv[1], argv[2]
    s = open(path).read()
    if len(re.findall(KEY, s, flags=re.M)) != 1:
        print("풀 크기 줄이 정확히 하나가 아니다", file=sys.stderr)
        return 2
    open(path, "w").write(re.sub(KEY, r"\g<1>" + n + r"\g<2>", s, flags=re.M))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
