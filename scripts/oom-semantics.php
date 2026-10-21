#!/usr/bin/env php
<?php

/**
 * OOM 语义回归测试（CVE-2026-109618 修复改变了 OOM 行为）。
 *
 * 修复要点：不再用 longjmp() 立即退出，而是在下一个 VM safe point 触发 soft OOM，
 * 超过第二阈值时用 _exit() 触发 hard OOM。这属于运行时语义变更，升级基础镜像后
 * 必须验证 memory_limit 仍然"真的"生效，否则等于悄悄失去内存保护。
 *
 * 在镜像内部执行：
 *   docker run --rm -v "$PWD/scripts:/gate:ro" <image> php /gate/oom-semantics.php
 *
 * 兼容 PHP 7.4 / 8.0：不使用 str_contains() 等 8.0+ 函数。
 *
 * 退出码：0 通过，1 失败
 */

declare(strict_types=1);

$failures = [];

/** PHP 7.4 没有 str_contains() */
function contains(string $haystack, string $needle): bool
{
    return $needle === '' || strpos($haystack, $needle) !== false;
}

/**
 * 以子进程运行一段 PHP 代码，返回 [exitCode, stdout, stderr]。
 *
 * @return array{code:int,out:string,err:string}
 */
function runChild(string $code, array $ini = []): array
{
    $cmd = [PHP_BINARY];
    foreach ($ini as $key => $value) {
        $cmd[] = '-d';
        $cmd[] = $key . '=' . $value;
    }
    $cmd[] = '-r';
    $cmd[] = $code;

    $descriptors = [
        0 => ['pipe', 'r'],
        1 => ['pipe', 'w'],
        2 => ['pipe', 'w'],
    ];

    $process = proc_open($cmd, $descriptors, $pipes);
    if (!is_resource($process)) {
        return ['code' => -1, 'out' => '', 'err' => 'proc_open failed'];
    }
    fclose($pipes[0]);
    $stdout = (string) stream_get_contents($pipes[1]);
    $stderr = (string) stream_get_contents($pipes[2]);
    fclose($pipes[1]);
    fclose($pipes[2]);
    $code = proc_close($process);

    return ['code' => $code, 'out' => $stdout, 'err' => $stderr];
}

function check(string $label, bool $ok, string $detail, array &$failures): void
{
    printf("[%-4s] %s%s\n", $ok ? 'PASS' : 'FAIL', $label, $detail === '' ? '' : ' — ' . $detail);
    if (!$ok) {
        $failures[] = $label;
    }
}

// R1: memory_limit 必须仍然生效，且仍产生可识别的 soft OOM 诊断
$soft = runChild('str_repeat("x", 64 * 1024 * 1024);', ['memory_limit' => '16M']);
$softOom = $soft['code'] !== 0
    && (contains($soft['err'], 'Allowed memory size') || contains($soft['out'], 'Allowed memory size'));
check('R1 soft OOM 语义', $softOom, sprintf('exit=%d', $soft['code']), $failures);

// R2: 单次超大分配（远超 memory_limit）必须终止子进程
$hard = runChild('$a = []; while (true) { $a[] = str_repeat("y", 1024 * 1024); }', ['memory_limit' => '16M']);
check('R2 超限分配终止子进程', $hard['code'] !== 0, sprintf('exit=%d', $hard['code']), $failures);

// R3: 连续 OOM 后进程模型仍然健康（父进程存活且可继续拉起正常子进程）
$sane = runChild('echo "ok";', ['memory_limit' => '16M']);
check('R3 OOM 后运行时健康', $sane['code'] === 0 && trim($sane['out']) === 'ok', sprintf('exit=%d', $sane['code']), $failures);

// R4: fatal error 必须反映在退出码上（用于确认 fatal 不会被静默吞掉）
$fatal = runChild('undefined_function_for_cve_gate();');
check('R4 fatal 退出码非零', $fatal['code'] !== 0, sprintf('exit=%d', $fatal['code']), $failures);

// R5: memory_limit=-1 时不应再由 PHP 自身拦截（确认当前生效值是有限值）
$unlimited = runChild('echo ini_get("memory_limit");', ['memory_limit' => '-1']);
check(
    'R5 memory_limit 可显式覆盖',
    $unlimited['code'] === 0 && trim($unlimited['out']) === '-1',
    sprintf('exit=%d', $unlimited['code']),
    $failures
);

echo "\n";
if ($failures !== []) {
    fwrite(STDERR, 'OOM 语义回归失败: ' . implode(', ', $failures) . "\n");
    exit(1);
}
echo "OOM 语义回归通过\n";
exit(0);
