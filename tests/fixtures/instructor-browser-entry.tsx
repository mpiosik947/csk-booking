// Component integration fixture. No real Auth, DB, service key or mail provider.
import { useState } from 'react';
import { createRoot } from 'react-dom/client';
import InstructorEvents from '../../app/instructor/InstructorEvents';
import InstructorSelector from '../../app/admin/events/InstructorSelector';
const query = new URLSearchParams(location.search);
function SelectorFixture() {
  const [selected, setSelected] = useState<string[]>([]);
  return <><InstructorSelector options={[
    { user_id:'a',display_name:'Instruktor Alfa' },{ user_id:'b',display_name:'Instruktor Beta' },
  ]} selected={selected} onChange={setSelected} /><output aria-label="Selected IDs">{selected.join(',')}</output></>;
}
createRoot(document.getElementById('root')!).render(query.has('selector') ? <SelectorFixture /> :
  <InstructorEvents slug="synthetic-b" eventId={query.get('eventId') ?? undefined} />);
