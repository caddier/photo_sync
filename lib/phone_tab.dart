import 'package:flutter/material.dart';

class PhoneTab extends StatelessWidget {
  const PhoneTab({super.key});
  
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text('Phone tab (add phone info UI here)', style: Theme.of(context).textTheme.titleLarge),
    );
  }
}
