import { SetMetadata } from '@nestjs/common';

export const PUBLIC_ROUTE = 'nene.publicRoute';
export const Public = () => SetMetadata(PUBLIC_ROUTE, true);
