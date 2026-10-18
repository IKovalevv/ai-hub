#!/usr/bin/env bats
# CI-обёртка над харнессами bash-слоя: сами они — plain bash, чтобы на маке их
# можно было гонять без bats прямо под /bin/bash 3.2 (целевой шелл скриптов
# хаба). Два теста, а не один: при падении сразу видно, какая часть сломалась.

@test "comment: argument parsing, input forms, dry-run, rollback and races under /bin/bash" {
    run /bin/bash "$BATS_TEST_DIRNAME/comment.sh"
    echo "$output"
    [ "$status" -eq 0 ]
}

@test "thread commands: reply, resolve, rollback and mentions under /bin/bash" {
    run /bin/bash "$BATS_TEST_DIRNAME/comment-threads.sh"
    echo "$output"
    [ "$status" -eq 0 ]
}
