enum AppRole { customer, officer }

class UserProfile {
  const UserProfile({
    required this.id,
    required this.email,
    required this.displayName,
    required this.role,
    this.phone,
    this.address,
  });

  factory UserProfile.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final email = json['email'];
    final displayName = json['displayName'];
    final role = switch (json['role']) {
      'customer' => AppRole.customer,
      'officer' => AppRole.officer,
      _ => throw const FormatException('Unsupported application role.'),
    };
    if (id is! String ||
        id.isEmpty ||
        (email != null && (email is! String || email.isEmpty)) ||
        displayName is! String ||
        displayName.trim().isEmpty ||
        (json['phone'] != null && json['phone'] is! String) ||
        (json['address'] != null && json['address'] is! String)) {
      throw const FormatException('Incomplete application profile.');
    }
    return UserProfile(
      id: id,
      email: email as String?,
      displayName: displayName,
      role: role,
      phone: json['phone'] as String?,
      address: json['address'] as String?,
    );
  }

  final String id;
  final String? email;
  final String displayName;
  final AppRole role;
  final String? phone;
  final String? address;
}
