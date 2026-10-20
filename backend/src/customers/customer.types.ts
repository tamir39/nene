export interface Account {
  id: string;
  accountNumber: string;
  type: 'checking' | 'saving' | 'mortgage';
  currency: string;
  balanceMinor: string;
  status: string;
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
