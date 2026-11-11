<?php
echo "=== SSL Connection Test ===\n\n";

// Test 1: cURL with SSL
echo "1. Testing cURL SSL connection...\n";
$ch = curl_init('https://www.google.com');
curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
curl_setopt($ch, CURLOPT_SSL_VERIFYPEER, true);
curl_setopt($ch, CURLOPT_TIMEOUT, 10);
$result = curl_exec($ch);
$httpCode = curl_getinfo($ch, CURLINFO_HTTP_CODE);
$error = curl_error($ch);
curl_close($ch);

if ($result !== false && $httpCode == 200) {
    echo "   ✓ cURL SSL connection successful (HTTP {$httpCode})\n";
} else {
    echo "   ✗ cURL SSL connection failed: {$error}\n";
}

// Test 2: file_get_contents with SSL
echo "\n2. Testing file_get_contents SSL connection...\n";
$context = stream_context_create([
    'ssl' => [
        'verify_peer' => true,
        'verify_peer_name' => true,
    ]
]);
$result = @file_get_contents('https://www.google.com', false, $context);
if ($result !== false) {
    echo "   ✓ file_get_contents SSL connection successful\n";
} else {
    $error = error_get_last();
    echo "   ✗ file_get_contents SSL connection failed: " . ($error ? $error['message'] : 'Unknown error') . "\n";
}

// Test 3: Check CA bundle info
echo "\n3. CA Bundle Information:\n";
$caFile = ini_get('openssl.cafile');
echo "   CA File: {$caFile}\n";
if (file_exists($caFile)) {
    $size = filesize($caFile);
    echo "   Size: " . number_format($size) . " bytes\n";
    $content = file_get_contents($caFile);
    $certCount = substr_count($content, '-----BEGIN CERTIFICATE-----');
    echo "   Certificates: {$certCount}\n";
}

echo "\n=== Test Complete ===\n";
