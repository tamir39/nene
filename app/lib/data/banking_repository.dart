import 'user_profile.dart';

class BankAccount {
  const BankAccount({
    required this.id,
    required this.accountNumber,
    required this.type,
    required this.currency,
    required this.balanceMinor,
    required this.status,
    this.isDemo = false,
    this.annualRateBps,
    this.monthlyProfitMinor,
    this.principalRemainingMinor,
    this.monthlyDueMinor,
    this.nextDueOn,
  });

  factory BankAccount.fromJson(Map<String, dynamic> json) {
    final balance = requiredText(json, 'balanceMinor');
    final currency = requiredText(json, 'currency');
    if (!RegExp(r'^-?\d+$').hasMatch(balance) ||
        !RegExp(r'^[A-Z]{3}$').hasMatch(currency)) {
      throw const FormatException('Invalid account amount.');
    }
    if (json.containsKey('isDemo') && json['isDemo'] is! bool) {
      throw const FormatException('Invalid demo marker.');
    }
    return BankAccount(
      id: requiredText(json, 'id'),
      accountNumber: requiredText(json, 'accountNumber'),
      type: requiredText(json, 'type'),
      currency: currency,
      balanceMinor: balance,
      status: requiredText(json, 'status'),
      isDemo: json['isDemo'] == true,
      annualRateBps: _rate(json['annualRateBps']),
      monthlyProfitMinor: _amount(json['monthlyProfitMinor']),
      principalRemainingMinor: _amount(json['principalRemainingMinor']),
      monthlyDueMinor: _amount(json['monthlyDueMinor']),
      nextDueOn: optionalText(json, 'nextDueOn'),
    );
  }

  final String id;
  final String accountNumber;
  final String type;
  final String currency;
  final String balanceMinor;
  final String status;
  final bool isDemo;
  final int? annualRateBps;
  final String? monthlyProfitMinor,
      principalRemainingMinor,
      monthlyDueMinor,
      nextDueOn;
  static int? _rate(Object? value) {
    if (value == null) return null;
    if (value is! int || value < 0 || value > 2000) {
      throw const FormatException('Invalid rate.');
    }
    return value;
  }

  static String? _amount(Object? value) {
    if (value == null) return null;
    if (value is! String || !RegExp(r'^\d+$').hasMatch(value)) {
      throw const FormatException('Invalid amount.');
    }
    return value;
  }

  String get typeLabel => switch (type) {
    'checking' => 'Checking account',
    'saving' => 'Saving account',
    'mortgage' => 'Mortgage account',
    _ => 'Account',
  };

  // VND has no fractional minor units. Keep integer precision even above the
  // floating-point safe range; unknown future currencies are labelled honestly.
  String get balanceLabel => amountLabel(balanceMinor);
  String amountLabel(String value) {
    final amount = BigInt.parse(value);
    final digits = amount.abs().toString();
    final grouped = digits.replaceAllMapped(
      RegExp(r'(\d)(?=(\d{3})+$)'),
      (match) => '${match[1]},',
    );
    final sign = amount.isNegative ? '-' : '';
    return currency == 'VND'
        ? '$sign$grouped VND'
        : '$sign$grouped minor units ($currency)';
  }
}

class CustomerSummary {
  const CustomerSummary({
    required this.id,
    required this.email,
    required this.displayName,
    this.phone,
    this.address,
  });

  factory CustomerSummary.fromJson(Map<String, dynamic> json) =>
      CustomerSummary(
        id: requiredText(json, 'id'),
        email: optionalText(json, 'email'),
        displayName: requiredText(json, 'displayName'),
        phone: optionalText(json, 'phone'),
        address: optionalText(json, 'address'),
      );

  final String id;
  final String? email;
  final String displayName;
  final String? phone;
  final String? address;
}

class CustomerDetail extends CustomerSummary {
  const CustomerDetail({
    required super.id,
    required super.email,
    required super.displayName,
    super.phone,
    super.address,
    required this.accounts,
  });

  factory CustomerDetail.fromJson(Map<String, dynamic> json) => CustomerDetail(
    id: requiredText(json, 'id'),
    email: optionalText(json, 'email'),
    displayName: requiredText(json, 'displayName'),
    phone: optionalText(json, 'phone'),
    address: optionalText(json, 'address'),
    accounts: parseAccounts(json['accounts']),
  );

  final List<BankAccount> accounts;
}

/// Held only for a pending creation request; never persist or log this object.
class CustomerDraft {
  const CustomerDraft({
    required this.email,
    required this.displayName,
    required this.phone,
    required this.address,
    required this.initialPassword,
  });

  final String email;
  final String displayName;
  final String? phone;
  final String? address;
  final String initialPassword;

  Map<String, Object?> toJson() => {
    'email': email,
    'displayName': displayName,
    'phone': phone,
    'address': address,
    'initialPassword': initialPassword,
  };
}

abstract interface class BankingRepository {
  Future<List<BankAccount>> getAccounts(String token);
  Future<UserProfile> updateContact(
    String token, {
    required String? phone,
    required String? address,
  });
  Future<CustomerDetail> createCustomer(
    String token,
    CustomerDraft draft,
    String idempotencyKey,
  );
  Future<List<CustomerSummary>> findCustomers(String token, String query);
  Future<CustomerDetail> getCustomer(String token, String id);
  Future<CustomerDetail> updateCustomer(
    String token,
    String id, {
    required String displayName,
    required String? phone,
    required String? address,
    required String requestReason,
  });
}

String requiredText(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String || value.trim().isEmpty) {
    throw const FormatException('Incomplete application data.');
  }
  return value;
}

String? optionalText(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value != null && value is! String) {
    throw const FormatException('Invalid application data.');
  }
  return value as String?;
}

List<BankAccount> parseAccounts(Object? value) {
  if (value is! List) {
    throw const FormatException('Missing account list.');
  }
  return List.unmodifiable(
    value.map((entry) {
      if (entry is! Map<String, dynamic>) {
        throw const FormatException('Invalid account.');
      }
      return BankAccount.fromJson(entry);
    }),
  );
}
