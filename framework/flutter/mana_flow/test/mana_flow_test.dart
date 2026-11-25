import 'package:flutter_test/flutter_test.dart';
import 'package:mana_flow/mana_flow.dart';

final class _InvoiceDraft {
  const _InvoiceDraft({
    this.customer = '',
    this.prefilledCustomer = false,
    this.amount = 0,
    this.channel = 'PIX',
  });

  final String customer;
  final bool prefilledCustomer;
  final double amount;
  final String channel;

  _InvoiceDraft copyWith({String? customer, double? amount, String? channel}) =>
      _InvoiceDraft(
        customer: customer ?? this.customer,
        prefilledCustomer: prefilledCustomer,
        amount: amount ?? this.amount,
        channel: channel ?? this.channel,
      );
}

void main() {
  test('advances, validates, tracks answered trail, and jumps back cleanly', () async {
    final ctrl = ManaFlowController<_InvoiceDraft>(
      initialDraft: const _InvoiceDraft(),
      steps: [
        ManaFlowStep<_InvoiceDraft>(
          id: 'customer',
          canAdvance: (d) => d.customer.trim().isNotEmpty,
          validate: (d) => d.customer.trim().isEmpty ? 'Informe o cliente' : null,
          summary: (d) => d.customer,
        ),
        ManaFlowStep<_InvoiceDraft>(
          id: 'amount',
          canAdvance: (d) => d.amount > 0,
          validate: (d) => d.amount <= 0 ? 'Informe o valor' : null,
          summary: (d) => 'R\$ ${d.amount.toStringAsFixed(0)}',
        ),
        ManaFlowStep<_InvoiceDraft>(
          id: 'channel',
          summary: (d) => d.channel,
        ),
      ],
    );

    expect(ctrl.currentStep.id, 'customer');
    expect(ctrl.next(), isFalse);
    expect(ctrl.errorText, 'Informe o cliente');

    ctrl.update(ctrl.draft.copyWith(customer: 'Clínica Vita'));
    expect(ctrl.next(), isTrue);
    expect(ctrl.currentStep.id, 'amount');
    expect(ctrl.answeredTrail.map((a) => a.text), ['Clínica Vita']);

    ctrl.update(ctrl.draft.copyWith(amount: 380));
    expect(ctrl.next(), isTrue);
    expect(ctrl.isLast, isTrue);
    expect(ctrl.answeredTrail.length, 2);

    // Jump back via answered chip
    expect(ctrl.jumpTo('customer'), isTrue);
    expect(ctrl.currentStep.id, 'customer');

    ctrl.jumpTo('channel');
    var submitted = false;
    final ok = await ctrl.submit((draft) async {
      submitted = draft.customer == 'Clínica Vita' && draft.amount == 380;
    });
    expect(ok, isTrue);
    expect(submitted, isTrue);
  });

  test('skips conditional steps via skipIf while keeping summary trail', () {
    final ctrl = ManaFlowController<_InvoiceDraft>(
      initialDraft: const _InvoiceDraft(
        customer: 'Studio Norte',
        prefilledCustomer: true,
      ),
      steps: [
        ManaFlowStep<_InvoiceDraft>(
          id: 'customer',
          skipIf: (d) => d.prefilledCustomer,
          summary: (d) => d.customer,
        ),
        const ManaFlowStep<_InvoiceDraft>(id: 'amount'),
      ],
    );

    expect(ctrl.stepCount, 1);
    expect(ctrl.currentStep.id, 'amount');
    expect(ctrl.answeredTrail.map((a) => a.text), ['Studio Norte']);
  });
}
