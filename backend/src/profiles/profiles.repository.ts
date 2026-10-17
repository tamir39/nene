import { Injectable } from '@nestjs/common';
import { DatabaseService } from '../database/database.service.js';

export interface UserProfileRow {
  id: string;
  display_name: string;
  role: 'customer' | 'officer';
  status: 'active' | 'disabled';
}

@Injectable()
export class ProfilesRepository {
  constructor(private readonly database: DatabaseService) {}

  async findById(id: string): Promise<UserProfileRow | undefined> {
    const rows = await this.database.query<UserProfileRow>(
      'SELECT id, display_name, role, status FROM bank.user_profiles WHERE id = $1',
      [id],
    );
    return rows[0];
  }
}
