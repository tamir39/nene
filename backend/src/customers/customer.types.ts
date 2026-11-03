export interface Account {
  id: string;
  accountNumber: string;
  type: 'checking' | 'saving' | 'mortgage';
  currency: string;
  balanceMinor: string;
  status: string;
  isDemo?: boolean;
  annualRateBps?: number | null;
  rateRevision?: number | null;
  monthlyProfitMinor?: string;
  principalRemainingMinor?: string | null;
  monthlyDueMinor?: string | null;
  nextDueOn?: string | null;
}

export interface Customer {
  id: string;
  email: string | null;
  displayName: string;
  phone: string | null;
  address: string | null;
}

export interface CustomerDetail extends Customer {
  accounts: Account[];
}

export interface ContactInput {
  phone: string | null;
  address: string | null;
}

export interface CreateCustomerInput extends ContactInput {
  email: string;
  displayName: string;
  initialPassword: string;
}

export interface EditCustomerInput extends ContactInput {
  displayName: string;
  requestReason: string;
}
