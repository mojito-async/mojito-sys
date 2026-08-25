import mojito_sys


def main():
    # Scaffold check (panel H2/M7): the `mojito_sys` package import path
    # must compile and load against the repo root (-I). Package symbols are
    # added by the S1 memory/abi lanes; this stays green as they land.
    print("pkg-import-ok")
