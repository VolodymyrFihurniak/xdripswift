# Sibionics 2 Troubleshooting Guide

## Поточна ситуація

✅ **Що працює:**
- Автопошук датчика через service UUID (FF30)
- Підключення до пристрою
- Фільтрація за назвою пристрою (P + 3 цифри)

❌ **Проблема:**
- Дані з датчика не надходять після підключення

## Можливі причини

### 1. Session Key проблема
**Симптом:** Датчик підключається, але не автентифікується
**Перевірка:** Логи мають показувати `authenticationAccepted`
**Рішення:** Перевірити `deriveSessionKey()` та `ecoRegistration`

### 2. Handshake не завершується
**Симптом:** Застряє на `awaitingAuthentication` або `awaitingTimeSync`
**Перевірка:** Логи Sibionics 2 FF31 response
**Рішення:** Перевірити послідовність команд

### 3. Factory Code відсутній
**Симптом:** Датчик стрімить, але readings показують "factory code missing"
**Перевірка:** `batchProcessor == nil`
**Рішення:** Встановити factory code/sensitivity датчика

### 4. Notification не обробляються
**Симптом:** Дані надходять, але не розпарсюються
**Перевірка:** Логи `parseV120` показують `.malformed`
**Рішення:** Перевірити шифрування/дешифрування

## Порівняння з JugglucoNG

### Критичні відмінності:

1. **Auto-start після streaming:**
```kotlin
// JugglucoNG автоматично запитує історію після streaming ready
if (phase == Phase.STREAMING && !initialDataFetched) {
    requestHistoricalData(lastIndex = 0)
    initialDataFetched = true
}
```

2. **Session Key derivation:**
```kotlin
// JugglucoNG: deriveSessionKey(variant)
// xDripSwift: deriveSessionKey() - фіксований ключ
```

3. **Battery reading:**
JugglucoNG зчитує рівень батареї з окремого characteristic перед auth

## Наступні кроки діагностики

1. Увімкнути детальне логування всіх BLE операцій
2. Перевірити, чи надходять notification на FF31
3. Перевірити, чи успішно проходить кожна фаза handshake
4. Перевірити, чи встановлений factory code
5. Порівняти зашифровані пакети з JugglucoNG

## Рекомендовані виправлення

### Пріоритет 1: Логування
Додати trace для кожної фази handshake та кожного notification

### Пріоритет 2: Factory Code
Переконатися, що factory sensitivity встановлена для активного датчика

### Пріоритет 3: Auto-history request
Після досягнення streaming автоматично запитувати історію даних
